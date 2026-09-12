# passthroughs of the -target flake's modules
{ inputs, ... }@top:
let
  subFlake = inputs.disko-install-menu-target;
in
{

  _class = "flake";

  flake.nixosModules = {
    inherit (subFlake.nixosModules) support test-configDefaults;
  };

  perSystem =
    { system, ... }:
    {
      nixosTemplates = subFlake.nixosTemplates.${system};
    };

}
