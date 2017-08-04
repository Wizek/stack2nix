let
  pkgs = import <nixpkgs> {};
in
  with (import <nixpkgs/pkgs/development/haskell-modules/lib.nix> { inherit pkgs; } ); 
  justStaticExecutables (import ./stack2nix.nix {}).stack2nix
