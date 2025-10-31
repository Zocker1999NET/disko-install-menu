{
  description = "Interactive Installer Menu for Flake-based NixOS Disko Configurations";

  inputs = {
    # for flake structure
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs"; # have full nixpkgs.lib
    };
    # for package
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    # for testing
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { nixpkgs, flake-parts, ... }@inputs:
    flake-parts.lib.mkFlake { inherit inputs; } (
      { self, lib, ... }@top:
      let
        inherit (lib.lists) singleton;
      in
      {
        imports = [
          ./support/default.nix
          ./tests/default.nix
        ];

        systems = [
          "x86_64-linux"
        ];

        flake = {
          nixosModules = rec {
            # with package already provided (allowing easier use)
            default.imports = [
              disko-install-menu
              package
            ];
            # raw module exported (assuming package being available in system’s pkgs)
            disko-install-menu = {
              imports = [ ./module.nix ];
            };
            # package as overlay & especially built for the given NixOS version
            package.nixpkgs.overlays = singleton (
              pkgs: _: {
                disko-install-menu = pkgs.callPackage ./package.nix { };
              }
            );
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
