{
  description = "Interactive Installer Menu for Flake-based NixOS Disko Configurations";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let

      inherit (builtins) attrNames;
      inherit (nixpkgs) lib;
      inherit (lib) genAttrs;

      supportedSystems = attrNames nixpkgs.legacyPackages;
      systemSpecificVars = system: {
        pkgs = import nixpkgs { inherit system; };
        inherit system;
      };
      forAllSystems = gen: genAttrs supportedSystems (system: gen (systemSpecificVars system));

    in
    {

      devShells = forAllSystems (
        { pkgs, ... }:
        rec {
          default = test-config;
          test-config = pkgs.mkShell {
            shellHook = ''
              export CONFIG_PATH=./test_config
            '';
          };
        }
      );

      nixosModules = rec {
        # with package from flake configured (allowing easier use)
        default = (
          { pkgs, ... }:
          {
            imports = [ disko-install-menu ];
            config.programs.disko-install-menu.package = self.packages.${pkgs.system}.disko-install-menu;
          }
        );
        # raw module exported (assuming package being available in system’s pkgs)
        disko-install-menu = import ./module.nix;
      };

      packages = forAllSystems (
        { pkgs, ... }:
        rec {
          default = disko-install-menu;
          disko-install-menu = pkgs.callPackage ./package.nix { };
        }
      );

    };
}
