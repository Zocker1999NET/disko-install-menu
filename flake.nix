{
  description = "Interactive Installer Menu for Flake-based NixOS Disko Configurations";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs =
    { nixpkgs, flake-parts, ... }@inputs:
    flake-parts.lib.mkFlake { inherit inputs; } (
      { self, lib, ... }@top:
      {
        systems = [
          "x86_64-linux"
        ];

        flake = {
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
            disko-install-menu = {
              imports = [ ./module.nix ];
            };
          };
        };

        perSystem =
          { pkgs, system, ... }:
          {

            devShells = rec {
              default = test-config;
              test-config = pkgs.mkShell {
                shellHook = ''
                  export CONFIG_PATH=./test_config
                '';
              };
            };

            packages = rec {
              default = disko-install-menu;
              disko-install-menu = pkgs.callPackage ./package.nix { };
            };

          };

      }
    );
}
