{ lib, ... }@top:
let
  inherit (lib.lists) singleton;
in
{

  imports = singleton ./nixosConfig.nix;

  perSystem =
    { pkgs, ... }@systemArg:
    {
      checks =
        let
          importTest = path: pkgs.nixosTest (import path top systemArg);
        in
        {
          installDefault = importTest ./installDefault.nix;
        };
    };

}
