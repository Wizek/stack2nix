{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Stack2nix
  ( Args(..)
  , stack2nix
  , version
  ) where

import           Control.Concurrent.Async
import           Control.Concurrent.MSem
import           Control.Exception            (onException)
import           Control.Monad                (unless, void)
import           Data.Char                    (toLower)
import           Data.Fix                     (Fix (..))
import           Data.List                    (foldl', isInfixOf, isSuffixOf,
                                               sort, union, (\\))
import qualified Data.Map.Strict              as Map
import           Data.Maybe                   (fromMaybe, listToMaybe)
import           Data.Monoid                  ((<>))
import           Data.Text                    (Text, pack, unpack)
import qualified Data.Traversable             as T
import           Data.Version                 (Version (..), parseVersion,
                                               showVersion)
import           Distribution.Text            (display)
import           Nix.Atoms                    (NAtom (..))
import           Nix.Expr                     (Binding (..), NExpr, NExprF (..),
                                               NKeyName (..), ParamSet (..),
                                               Params (..))
import           Nix.Parser                   (Result (..), parseNixFile,
                                               parseNixString)
import           Nix.Pretty                   (prettyNix)
import           Path                         (parseAbsFile)
import           Paths_stack2nix              (version)
import           Stack.Config
import           Stack.Prelude                (LogLevel (..), runRIO)
import           Stack.Types.BuildPlan
import           Stack.Types.Config
import           Stack.Types.Runner
import           Stack2nix.External           (cabal2nix)
import           Stack2nix.External.Util      (runCmd, runCmdFrom)
import           Stack2nix.External.VCS.Git   (Command (..), ExternalCmd (..),
                                               InternalCmd (..), git)
import           System.Directory             (canonicalizePath, doesFileExist)
import           System.Environment           (getEnv)
import           System.Exit                  (ExitCode (..))
import           System.FilePath              (dropExtension, isAbsolute,
                                               normalise, takeDirectory,
                                               takeFileName, (<.>), (</>))
import           System.FilePath.Glob         (glob)
import           System.IO                    (hPutStrLn, stderr)
import           System.IO.Temp               (withSystemTempDirectory)
import           Text.ParserCombinators.ReadP (readP_to_S)

data Args = Args
  { argRev     :: Maybe String
  , argOutFile :: Maybe FilePath
  , argThreads :: Int
  , argTest    :: Bool
  , argHaddock :: Bool
  , argUri     :: String
  }
  deriving (Show)

checkRuntimeDeps :: IO ()
checkRuntimeDeps = do
  checkVer "cabal2nix" "2.2.1"
  checkVer "git" "2"
  checkVer "cabal" "1"
  where
    checkVer prog minVer = do
      hPutStrLn stderr $ unwords ["Ensuring", prog, "version is >=", minVer, "..."]
      result <- runCmd prog ["--version"] `onException` error ("Failed to run " ++ prog ++ ". Not found in PATH.")
      case result of
        (ExitSuccess, out, _) ->
          let
            -- heuristic for parsing version from stdout
            firstLine = head . lines
            lastWord = last . words
            ver = parseVer . lastWord . firstLine $ out
          in
          unless (ver >= parseVer minVer) $ error $ unwords ["ERROR:", prog, "version must be", minVer, "or higher. Current version:", maybe "[parse failure]" showVersion ver]
        (ExitFailure _, _, err)  -> error err

    parseVer :: String -> Maybe Version
    parseVer =
      fmap fst . listToMaybe . reverse . readP_to_S parseVersion

stack2nix :: Args -> IO ()
stack2nix args@Args{..} = do
  checkRuntimeDeps
  updateCabalPackageIndex
  isLocalRepo <- doesFileExist $ argUri </> "stack.yaml"
  if isLocalRepo
  then handleStackConfig Nothing argUri
  else withSystemTempDirectory "s2n-" $ \tmpDir ->
    tryGit tmpDir >> handleStackConfig (Just argUri) tmpDir
  where
    updateCabalPackageIndex :: IO ()
    updateCabalPackageIndex =
      getEnv "HOME" >>= \home -> void $ runCmdFrom home "cabal" ["update"]

    tryGit :: FilePath -> IO ()
    tryGit tmpDir = do
      void $ git $ OutsideRepo $ Clone argUri tmpDir
      case argRev of
        Just r  -> do
          void $ git $ InsideRepo tmpDir (Checkout r)
          return mempty
        Nothing -> return mempty

    handleStackConfig :: Maybe String -> FilePath -> IO ()
    handleStackConfig remoteUri localDir = do
      let stackFile = localDir </> "stack.yaml"
      alreadyExists <- doesFileExist stackFile
      unless alreadyExists $ void $ runCmdFrom localDir "stack" ["init", "--system-ghc"]
      cp <- canonicalizePath stackFile
      fp <- parseAbsFile cp
      lc <- withRunner LevelError True False ColorAuto False $ \runner -> do
        -- https://www.fpcomplete.com/blog/2017/07/the-rio-monad
        runRIO runner $ loadConfig mempty Nothing (SYLOverride fp)
      buildConfig <- lcLoadBuildConfig lc Nothing -- compiler
      toNix args remoteUri localDir buildConfig

-- Credit: https://stackoverflow.com/a/18898822/204305
mapPool :: T.Traversable t => Int -> (a -> IO b) -> t a -> IO (t b)
mapPool max' f xs = do
  sem <- new max'
  mapConcurrently (with sem . f) xs

toNix :: Args -> Maybe String -> FilePath -> BuildConfig -> IO ()
toNix Args{..} remoteUri baseDir BuildConfig{..} =
  withSystemTempDirectory "s2n" $ \outDir -> do
    mapPool argThreads (curry genNixFile outDir) (fmap PLOther bcPackages ++ bcDependencies) >>= mapM_ (handleGenNixFileResult 1)
    -- Generate full dependency graph by stack and generate packages
    -- NOTE: this will download git and other packages to compute the full graph
    -- TODO: filter out local dependencies
    overrides <- mapPool argThreads overrideFor =<< updateDeps outDir
    -- Override Nix files for local/Repo packages
    mapPool argThreads (curry genNixFile outDir) (fmap PLOther bcPackages ++ bcDependencies) >>= mapM_ (handleGenNixFileResult 1)
    nixFiles <- glob (outDir </> "*.nix")
    void $ mapPool argThreads patchNixFile nixFiles
    writeFile (outDir </> "initialPackages.nix") $ initialPackages $ sort overrides
    pullInNixFiles $ outDir </> "initialPackages.nix"
    nf <- parseNixFile $ outDir </> "initialPackages.nix"
    case nf of
      Success expr ->
        case argOutFile of
          Just fname -> writeFile fname $ defaultNix expr
          Nothing    -> putStrLn $ defaultNix expr
      _ -> error "failed to parse intermediary initialPackages.nix file"
      where
        updateDeps :: FilePath -> IO [FilePath]
        updateDeps outDir = do
          hPutStrLn stderr $ "Updating deps from " ++ baseDir
          result <- runCmdFrom baseDir "stack" ["list-dependencies", "--nix", "--system-ghc", "--test", "--separator", "-"]
          case result of
            (ExitSuccess, pkgs, _) -> do
              -- TODO: filter out pkgs that are part of bcPackages/bcDependencies
              let pkgs' = ["hscolour", "jailbreak-cabal", "cabal-doctest", "happy", "stringbuilder"] ++ lines pkgs
              hPutStrLn stderr "Haskell dependencies:"
              mapM_ (hPutStrLn stderr) pkgs'
              mapPool argThreads (curry handleStackDep outDir) (pack <$> pkgs') >>= mapM_ (handleStackDepResult 1)
              return ()
            (ExitFailure _, _, err) ->
              error $ unlines ["FAILED: stack list-dependencies", err]
          glob (outDir </> "*.nix")

        genNixFile :: (FilePath, PackageLocationIndex Subdirs) -> IO ((FilePath, PackageLocationIndex Subdirs), (ExitCode, String, String))
        genNixFile (_, pli@(PLIndex _)) = return (("", pli), (ExitSuccess, "", ""))
        genNixFile input@(outDir, PLOther (PLFilePath relPath)) = do
          r <- cabal2nix (fromMaybe (baseDir </> relPath) remoteUri) (pack <$> argRev) (const relPath <$> remoteUri) (Just outDir)
          return (input, r)
        genNixFile input@(outDir, PLOther (PLRepo repo)) = do
          case repoSubdirs repo of
            ExplicitSubdirs sds -> do
              result <- mapM (\sd -> cabal2nix (unpack (repoUrl repo)) (Just (repoCommit repo)) (Just sd) (Just outDir) >>=
                               (\r -> return (input, r))) (sds)
              pure . head $ result
            DefaultSubdirs -> do
              r <- cabal2nix (unpack (repoUrl repo)) (Just (repoCommit repo)) Nothing (Just outDir)
              return (input, r)
        genNixFile _input@(_outDir, PLOther (PLArchive _)) = do
           error "PLArchive not implemented yet"

        handleGenNixFileResult :: Int -> ((FilePath, PackageLocationIndex Subdirs), (ExitCode, String, String)) -> IO ()
        handleGenNixFileResult _ (_input@(_, p), (ExitSuccess, _, _)) =
          hPutStrLn stderr $ "Nix expression generated for '" <> show p <> "'"
        handleGenNixFileResult retries (input@(_, p), (ExitFailure c, out, err)) = do
          hPutStrLn stderr $ "Failed to generate nix expression for '" <> show p <> "'."
          if retries > 0
            then
            do
              hPutStrLn stderr "Retrying..."
              genNixFile input >>= handleGenNixFileResult (retries - 1)
            else error $ unlines [ "ERROR: (" <> show c <> ") failed to generated nix expression for '" <> show input <> "'"
                                 , "\tstderr: " <> err
                                 , "\tstdout: " <> out
                                 ]

        -- Given a path to a package with Cabal file inside, return Cabal package name
        localPackageName :: FilePath -> IO String
        localPackageName dir = do
          [cabal] <- glob (dir </> "*.cabal")
          contents <- readFile cabal
          let nameLine = head $ [x | x <- lines contents, "name" `isInfixOf` map toLower x]
          pure . reverse . takeWhile (/= ' ') . reverse $ nameLine

        -- Returns a list of names of local packages
        localPackages :: IO [String]
        localPackages = do
          mapM (\p -> case p of
                        PLFilePath subDir -> localPackageName (baseDir </> subDir)
                        PLArchive _ -> error "Arhive local dependencies not supported"
                        PLRepo _ -> error "Repo local dependencies not supported") bcPackages

        patchNixFile :: FilePath -> IO ()
        patchNixFile fname = do
          contents <- readFile fname
          case parseNixString contents of
            Success expr ->
              case takeFileName fname of
                "hspec.nix" ->
                  writeFile fname $ show $ prettyNix $ (addParam "stringbuilder" . stripNonEssentialDeps False) expr
                _ -> do
                  pkgs <- localPackages
                  let
                    shouldPatch = any (\p -> (p <.> "nix") `isSuffixOf` fname) pkgs
                    shouldTest = argTest && shouldPatch
                    expr' = stripNonEssentialDeps shouldTest (if shouldTest then enableCheck expr else expr)
                    expr'' = if (argHaddock && shouldPatch) then enableHaddock expr' else expr'
                  writeFile fname $ show $ prettyNix expr''
            _ -> error "failed to parse intermediary nix package file"

        enableCheck :: NExpr -> NExpr
        enableCheck expr =
          case expr of
            Fix (NAbs paramSet (Fix (NApp mkDeriv (Fix (NSet attrs))))) ->
              let attrs' = map patchAttr attrs in
              Fix (NAbs paramSet (Fix (NApp mkDeriv (Fix (NSet attrs')))))
            _ ->
              error $ "unhandled nix expression format\n" ++ show expr
          where
            patchAttr :: Binding (Fix NExprF) -> Binding (Fix NExprF)
            patchAttr attr =
              case attr of
                NamedVar [StaticKey "doCheck"] (Fix (NConstant (NBool False))) ->
                  NamedVar [StaticKey "doCheck"] (Fix (NConstant (NBool True)))
                x -> x

        enableHaddock :: NExpr -> NExpr
        enableHaddock expr =
          case expr of
            Fix (NAbs paramSet (Fix (NApp mkDeriv (Fix (NSet attrs))))) ->
              let attrs' = map patchAttr attrs in
              Fix (NAbs paramSet (Fix (NApp mkDeriv (Fix (NSet attrs')))))
            _ ->
              error $ "unhandled nix expression format\n" ++ show expr
          where
            patchAttr :: Binding (Fix NExprF) -> Binding (Fix NExprF)
            patchAttr attr =
              case attr of
                NamedVar [StaticKey "doHaddock"] (Fix (NConstant (NBool False))) ->
                  NamedVar [StaticKey "doHaddock"] (Fix (NConstant (NBool True)))
                x -> x

        addParam :: String -> NExpr -> NExpr
        addParam param expr =
          let contents = show $ prettyNix expr
              (l:ls) = lines contents
              (openBrace, params) = splitAt 1 (words l)
              l' = unwords $ openBrace ++ [param ++ ", "] ++ params
          in
          case parseNixString $ unlines (l':ls) of
            Success expr' -> expr'
            _             -> expr

        stripNonEssentialDeps :: Bool -> NExpr -> NExpr
        stripNonEssentialDeps keepTests expr =
          let benchSects = ["benchmarkHaskellDepends", "benchmarkToolDepends"]
              testSects = ["testHaskellDepends", "testToolDepends"]
              otherSects = [ "executableHaskellDepends"
                           , "executableToolDepends"
                           , "libraryHaskellDepends"
                           , "librarySystemDepends"
                           , "libraryToolDepends"
                           , "setupHaskellDepends"
                           ]
              sectsToDrop = if keepTests then benchSects else benchSects `union` testSects
              sectsToKeep = if keepTests then otherSects `union` testSects else otherSects
              collectDeps sects = foldr union [] $ fmap (dependenciesFromSection expr) sects
              depsToStrip = collectDeps sectsToDrop \\ collectDeps sectsToKeep
              expr' = foldl dropDependencySection expr sectsToDrop
          in
          dropParams expr' depsToStrip

        handleStackDep :: (FilePath, Text) -> IO ((FilePath, Text), (ExitCode, String, String))
        handleStackDep input@(outDir, dep) = do
          output <- cabal2nix ("cabal://" <> unpack dep) Nothing Nothing (Just outDir)
          return (input, output)

        handleStackDepResult :: Int -> ((FilePath, Text), (ExitCode, String, String)) -> IO ()
        handleStackDepResult _ ((_, p), (ExitSuccess, _, _)) =
          hPutStrLn stderr $ "Handled stack dependency '" <> show p <> "'."
        handleStackDepResult retries (input@(_, p), (ExitFailure c, out, err)) = do
          hPutStrLn stderr $ "Failed to handle stack dependency '" <> show p <> "'."
          if retries > 0
            then
            do
              hPutStrLn stderr "Retrying..."
              handleStackDep input >>= handleStackDepResult (retries - 1)
            else hPutStrLn stderr $ unlines [ "NON-FATAL ERROR: (" <> show c <> ") failed to generated nix expression for '" <> show p <> "'"
                                            , "\tstderr: " <> err
                                            , "\tstdout: " <> out
                                            ]

        overrideFor :: FilePath -> IO String
        overrideFor nixFile = do
          deps <- externalDeps
          return $ "    " <> (dropExtension . takeFileName) nixFile <> " = callPackage ./" <> takeFileName nixFile <> " { " <> deps <> " };"
          where
            externalDeps :: IO String
            externalDeps = do
              deps <- librarySystemDeps nixFile
              return . unwords $ fmap (\d -> unpack d <> " = pkgs." <> unpack d <> ";") deps

        pullInNixFiles :: FilePath -> IO ()
        pullInNixFiles nixFile = do
          nf <- parseNixFile nixFile
          case nf of
            Success expr ->
              case expr of
                Fix (NAbs paramSet (Fix (NAbs fnParam (Fix (NSet attrs))))) -> do
                  attrs' <- mapM patchAttr attrs
                  let expr' = Fix (NAbs paramSet (Fix (NAbs fnParam (Fix (NSet attrs')))))
                  writeFile nixFile $ (++ "\n") $ show $ prettyNix expr'
                _ ->
                  error $ "unhandled nix expression format\n" ++ show expr
            _ -> error "failed to parse nix file!"
            where
              patchAttr :: Binding (Fix NExprF) -> IO (Binding (Fix NExprF))
              patchAttr attr =
                case attr of
                  NamedVar k (Fix (NApp (Fix (NApp (Fix (NSym "callPackage")) pkg)) deps)) -> do
                    pkg' <- patchPkgRef pkg
                    return $ NamedVar k (Fix (NApp (Fix (NApp (Fix (NSym "callPackage")) pkg')) deps))
                  _ -> error "unhandled NamedVar"

              patchPkgRef (Fix (NLiteralPath path)) = do
                let p = if isAbsolute path then path else normalise $ takeDirectory nixFile </> path
                nf <- parseNixFile p
                case nf of
                  Success expr -> return expr
                  _ -> error $ "failed to parse referenced nix file '" ++ path ++ "'"
              patchPkgRef x                   = return x

        dependenciesFromSection :: NExpr -> String -> [Text]
        dependenciesFromSection expr name =
          case expr of
            Fix (NAbs _ (Fix (NApp _ (Fix (NSet namedVars))))) ->
              case lookupNamedVar namedVars name of
                Just (Fix (NList deps)) ->
                  foldl' (\acc x ->
                            case x of
                              Fix (NSym n) -> n : acc
                              _            -> acc) [] deps
                _ -> []
            _ -> []

        librarySystemDeps :: FilePath -> IO [Text]
        librarySystemDeps nixFile = do
          nf <- parseNixFile nixFile
          case nf of
            Success expr -> return $ dependenciesFromSection expr "librarySystemDepends"
            _            -> return []

        dropDependencySection :: NExpr -> String -> NExpr
        dropDependencySection expr name =
          case expr of
            Fix (NAbs a (Fix (NApp b (Fix (NSet namedVars))))) ->
              Fix (NAbs a (Fix (NApp b (Fix (NSet $ dropNamedVar namedVars name)))))
            _ -> expr

        lookupNamedVar :: [Binding a] -> String -> Maybe a
        lookupNamedVar [] _ = Nothing
        lookupNamedVar (x:xs) name =
          case x of
            NamedVar [StaticKey k] val ->
              if unpack k == name
              then Just val
              else lookupNamedVar xs name
            _ -> lookupNamedVar xs name

        dropNamedVar :: [Binding a] -> String -> [Binding a]
        dropNamedVar xs name = filter differentName xs
          where
            differentName (NamedVar [StaticKey k] _) = unpack k /= name
            differentName _                          = True

        dropParams :: NExpr -> [Text] -> NExpr
        dropParams (Fix (NAbs (ParamSet (FixedParamSet paramMap) x)
                    (Fix (NApp mkDeriv (Fix (NSet args)))))) names =
          Fix (NAbs (ParamSet (FixedParamSet $ foldr Map.delete paramMap names) x)
                    (Fix (NApp mkDeriv (Fix (NSet args)))))
        dropParams x _ = x

        initialPackages overrides = unlines $
          [ "{ pkgs, stdenv, callPackage }:"
          , ""
          , "self: {"
          ] ++ overrides ++
          [ "}"
          ]

        defaultNix pkgsNixExpr = unlines
          [ "# Generated using stack2nix " ++ display version ++ "."
          , "#"
          , "# Only works with sufficiently recent nixpkgs, e.g. \"NIX_PATH=nixpkgs=https://github.com/NixOS/nixpkgs/archive/21a8239452adae3a4717772f4e490575586b2755.tar.gz\"."
          , ""
          , "{ pkgs ? (import <nixpkgs> {})"
          , ", compiler ? pkgs.haskell.packages.ghc802"
          , ", ghc ? pkgs.haskell.compiler.ghc802"
          , "}:"
          , ""
          , "with (import <nixpkgs/pkgs/development/haskell-modules/lib.nix> { inherit pkgs; });"
          , ""
          , "let"
          , "  stackPackages = " ++ show (prettyNix pkgsNixExpr) ++ ";"
          , "in"
          , "compiler.override {"
          , "  initialPackages = stackPackages;"
          , "  configurationCommon = { ... }: self: super: {};"
          , "}"
          ]
