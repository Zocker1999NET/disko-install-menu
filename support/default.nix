{ lib, ... }@top:
let
  inherit (lib.lists) singleton;
in
{
  flake.nixosModules.support.imports = singleton ./module.nix;
}
