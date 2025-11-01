{ lib, ... }@top:
let
  inherit (lib.lists) singleton;
in
{

  imports = [
    ./_configDefaults.nix
    ./descriptionFallback.nix
    ./nixosConfig.nix
  ];

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
