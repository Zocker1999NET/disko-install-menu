{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.disko-install-menu;

  inherit (builtins)
    attrValues
    concatLists
    concatStringsSep
    filter
    head
    length
    mapAttrs
    ;
  inherit (lib) types;
  inherit (lib.attrsets) filterAttrs genAttrs;
  inherit (lib.lists) singleton;
  inherit (lib.modules) mkIf;
  inherit (lib.options) mkEnableOption mkOption;
  inherit (lib.strings) escapeNixIdentifier;
  inherit (lib.trivial) flip pipe;

  mkDisableOption = text: mkEnableOption text // { default = true; };

  cfgFormat = pkgs.formats.json { };

  attrNamesToTrue = with types; coercedTo (listOf str) (flip genAttrs (_: true)) (attrsOf bool);
  flakesType = types.submodule (
    { name, options, ... }:
    {
      freeformType = cfgFormat.type;
      options = {
        enabled = mkDisableOption "this flake entry";
        name = mkOption {
          description = "Name of this flake entry attr, used primarily for assertions and error messages.";
          internal = true;
          readOnly = true;
          type = types.str;
          default = name;
        };
        title = mkOption {
          description = "Title of this flake entry, displayed to the user.";
          type = types.str;
          default = name;
          example = "My Cool Flake";
        };
        reference = mkOption {
          description = ''
            Flake reference of this entry. The flake entry may be locked or unlocked.
          '';
          # weird trick to make it accept null if offlineReference is also declared
          #   because ./offlineCapable.nix cannot override its type to accept null
          #   and it must not allow null as part of the passthrough options
          type = if options ? offlineReference then with types; nullOr str else types.str;
          example = "github:zocker-nix-projects/disko-install-menu";
        };
        isDefaultFlake = mkOption {
          description = ''
            Whether this flake entry is the default flake entry.

            If enabled,
            {option}`programs.disko-install-menu.listedFlakes.${name}.defaultHost`
            is expected to be configured as well.
          '';
          type = types.bool;
          default = false;
          example = true;
        };
        defaultHost = mkOption {
          description = ''
            If set, the default host configuration to be used from this flake entry.

            If declared, it serves as the default for speeding up selection of a configuration.
            Depending on {option}`programs.disko-install-menu.options.allowFlakeInput`
            or {option}`programs.disko-install-menu.options.listedFlakes`,
            users may still choose to install a different configuration at all.

            In general, for a NixOS configuration to be installable by this setup,
            it must also define a disko configuration
            (optionally excluding the names of the target disks,
            as those are provided by the user).

            if this is the default flake entry according to
            {option}`programs.disko-install-menu.listedFlakes.${name}.isDefaultFlake`,
            this host is used as the global default host configuration for the menu.
            Otherwise, this option is ignored for now.
          '';
          type = with types; nullOr str;
          default = null;
          example = "empty";
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
        type = types.attrsOf flakesType;
        example = singleton "github:Zocker1999NET/server";
        apply = flip pipe [
          attrValues
          (filter (v: v.enabled))
          (map (v: {
            inherit (v)
              name
              title
              reference
              isDefaultFlake
              defaultHost
              offlineHosts
              ;
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

  # assertions for both .options.listedFlakes & .listedFlakes directly
  # TODO replace with <server> flake's assertions passthrough module complex
  entryAssertions =
    prefix: entries:
    let
      defaultFlakesAll = filter (v: v.isDefaultFlake) entries;
      defaultFlakeCount = length defaultFlakesAll;
      defaultFlake = head defaultFlakesAll;
    in
    [
      {
        assertion = entries != [ ];
        message = "${prefix}: must not be empty";
      }
      # TODO adapt setup.py to support having no default flake
      {
        assertion = defaultFlakeCount >= 1;
        message = "${prefix}: must contain at least one default flake entry";
      }
      {
        assertion = defaultFlakeCount <= 1;
        message = ''
          ${prefix}: must not contain more than one default flake entry:
          ${concatStringsSep "\n" (map (f: "- .${escapeNixIdentifier f.name}") defaultFlakesAll)}
        '';
      }
      {
        assertion = defaultFlakeCount != 1 || defaultFlake.defaultHost != null;
        message = ''
          ${prefix}.${escapeNixIdentifier defaultFlake.name}: must declare a defaultHost if it is the default flake entry
        '';
      }
    ];
in
{

  _class = "nixos";

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

    assertions = concatLists [
      (entryAssertions "programs.disko-install-menu.listedFlakes" (attrValues cfg.listedFlakes))
      (entryAssertions "programs.disko-install-menu.options.listedFlakes" cfg.options.listedFlakes)
    ];

    # moved to /etc so config applies when disko-install-menu is just called by itself
    environment.etc."disko-install-menu/config".source =
      cfgFormat.generate "disko-install-menu-config" cfg.options;

    programs.disko-install-menu = {

      # options translation
      options = {
        listedFlakes = pipe cfg.listedFlakes [
          (filterAttrs (_: v: v.enabled))
          (mapAttrs (
            _: v: {
              inherit (v)
                title
                reference
                isDefaultFlake
                defaultHost
                ;
            }
          ))
        ];
      };

    };

  };

}
