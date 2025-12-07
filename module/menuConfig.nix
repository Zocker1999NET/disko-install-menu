# type: NixOS module
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.disko-install-menu;

  inherit (builtins) attrValues filter mapAttrs;
  inherit (lib) types;
  inherit (lib.attrsets) filterAttrs genAttrs;
  inherit (lib.lists) singleton;
  inherit (lib.modules) mkIf;
  inherit (lib.options) mkEnableOption mkOption;
  inherit (lib.trivial) flip pipe;

  mkDisableOption = text: mkEnableOption text // { default = true; };

  cfgFormat = pkgs.formats.json { };

  attrNamesToTrue = with types; coercedTo (listOf str) (flip genAttrs (_: true)) (attrsOf bool);
  flakesType = types.submodule (
    { name, ... }:
    {
      freeformType = cfgFormat.type;
      options = {
        enabled = mkDisableOption "this flake entry";
        title = mkOption {
          description = "Title of this flake entry, displayed to the user.";
          type = types.str;
          default = name;
          example = "My Cool Flake";
        };
        reference = mkOption {
          description = ''
            Flake reference of this entry. The flake entry may be locked or unlocked.

            To hide an entry, set its reference to `null`.
          '';
          type = with types; nullOr str;
          default = name;
          example = "github:Zocker1999NET/disko-install-menu";
        };
        # defined here because required for clean export
        offlineHosts = mkOption {
          description = ''
            Selects which configurations are cached for offline installations.

            - configurations are referred to by their name in the attrset `nixosConfigurations`
            - include configs by adding their name to the list or setting their value to `true`
            - exclude configs by setting their value to `false`
            - if no configs are explicitly included, all are implicitly included

            Only applicable if {option}`.offlineReference` is not set to `false`.
          '';
          type = attrNamesToTrue;
          default = { };
          example = singleton "test-x86_64-linux";
        };
      };
    }
  );
  flakesTypeCoerced =
    with types;
    coercedTo (listOf str) (flip genAttrs (_: {
      enabled = true;
    })) (attrsOf flakesType);

  menuOptions = types.submodule {
    freeformType = cfgFormat.type;
    options = {

      allowFlakeInput = mkOption {
        description = ''
          Whether to allow users to input a custom flake spec.

          When this option is disabled,
          only configurations provided via explicitly configured flakes or configurations
          can be installed by users of disko-install-menu.
        '';
        type = types.bool;
        default = true;
        example = false;
      };

      debugMode = mkEnableOption "debug (i.e. dry-run) mode, where no changes will be applied by the install menu";

      defaultFlake = mkOption {
        description = ''
          The flake where the default host config as specified in
          {option}`programs.disko-install-menu.options.defaultHost` lives.

          The flake listed this in option is also added to
          {option}`programs.disko-install-menu.listedFlakes`.
          Read that option’s documentation for further explaination.
        '';
        type = types.str;
        example = "github:Zocker1999NET/server";
      };

      defaultHost = mkOption {
        description = ''
          The name of the default host configuration provided in the menu.

          If declared, it only serves as the default for speeding up selection of a configuration.
          Depending on {option}`programs.disko-install-menu.options.allowFlakeInput`
          or {option}`programs.disko-install-menu.options.listedFlakes`,
          users may still choose to install a different configuration at all.

          This configuration is expected to be exported by the default flake as defined in
          {option}`programs.disko-install-menu.options.defaultFlake`.

          In general, for a NixOS configuration to be installable by this setup,
          it must also define a disko configuration
          (optionally excluding the names of the target disks,
          as those are provided by the user).
        '';
        type = types.str;
        example = "empty";
      };

      diskoInstallFlags = mkOption {
        description = "Command line arguments which are forwarded to disko-install.";
        type = with types; listOf str;
        default = [ ];
      };

      listedFlakes = mkOption {
        description = ''
          The flakes suggested in the menu.

          This option is used internally.
          Prefer {option}`programs.disko-install-menu.listedFlakes`.
        '';
        internal = true;
        type = flakesTypeCoerced;
        example = singleton "github:Zocker1999NET/server";
        apply = flip pipe [
          attrValues
          (filter (v: v.enabled))
          (map (v: {
            inherit (v) title reference offlineHosts;
          }))
        ];
      };

      writeEfiBootEntries = mkOption {
        description = ''
          Whether to enable writing EFI boot entries on installation.

          This is a tri-state variable,
          where the default value `null` means:
          Depend on the option {option}`boot.loader.efi.canTouchEfiVariables`
          of the selected configuration to be installed.
          This is because the setup is expected to be executed on the actual target machines.

          This `null` value allows you e.g.
          to disable this in configurations intended for systems
          where writing EFI variables might error out.

          Disable this if you want to execute the setup on non-target machines,
          e.g. when installing on external drives to deploy them later in their actual targets.

          Enable this only if you want to write EFI boot entries for every configuration.
        '';
        type = types.enum [
          false
          null
          true
        ];
        default = null;
      };

    };
  };
in
{

  options.programs.disko-install-menu = {
    options = mkOption {
      description = ''
        Passthrough options for disko-install-menu.
      '';
      type = menuOptions;
      default = { };
    };
    listedFlakes = mkOption {
      description = ''
        The flakes suggested in the menu.

        If declared, this list serves as a shortcut for speeding up selection of a configuration.
        Depending on {option}`programs.disko-install-menu.options.allowFlakeInput`,
        users may still choose to install from other flakes by inserting these flake references manually on runtime.

        Do not declare a specific configuration here (i.e. do not add `#host` to the end of the reference).
        To declare a default configuration, use the specific option for that.

        In general, for this menu to recognize a flake’s configurations,
        it must declare them in its nixosConfigurations output.
        The same as e.g. nixos-rebuild requires that output to be set.
      '';
      type = types.attrsOf flakesType;
      default = { };
      example = singleton "github:Zocker1999NET/server";
    };
  };

  config = mkIf cfg.enable {
    # moved to /etc so config applies when disko-install-menu is just called by itself
    environment.etc."disko-install-menu/config".source =
      cfgFormat.generate "disko-install-menu-config" cfg.options;

    programs.disko-install-menu = {

      # default options
      listedFlakes.defaultFlake = {
        title = "default flake";
        reference = cfg.options.defaultFlake;
      };

      # options translation
      options = {
        listedFlakes = pipe cfg.listedFlakes [
          (filterAttrs (_: v: v.enabled))
          (mapAttrs (
            _: v: {
              inherit (v) title reference;
            }
          ))
        ];
      };

    };
  };

}
