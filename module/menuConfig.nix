# type: NixOS module
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.disko-install-menu;

  inherit (lib) types;
  inherit (lib.lists) singleton;
  inherit (lib.modules) mkIf;
  inherit (lib.options) mkEnableOption mkOption;

  cfgFormat = pkgs.formats.json { };

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
          {option}`programs.disko-install-menu.options.listedFlakes`.
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

          If declared, this list serves as a shortcut for speeding up selection of a configuration.
          Depending on {option}`programs.disko-install-menu.options.allowFlakeInput`,
          users may still choose to install from other flakes by inserting these flake references manually on runtime.

          Do not declare a specific configuration here (i.e. do not add `#host` to the end of the reference).
          To declare a default configuration, use the specific option for that.

          In general, for this menu to recognize a flake’s configurations,
          it must declare them in its nixosConfigurations output.
          The same as e.g. nixos-rebuild requires that output to be set.
        '';
        type = with types; listOf str;
        example = singleton "github:Zocker1999NET/server";
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
  };

  config = mkIf cfg.enable {
    # moved to /etc so config applies when disko-install-menu is just called by itself
    environment.etc."disko-install-menu/config".source =
      cfgFormat.generate "disko-install-menu-config" cfg.options;

    # default options
    programs.disko-install-menu.options = {
      listedFlakes = singleton cfg.options.defaultFlake;
    };
  };

}
