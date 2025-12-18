# type: NixOS module
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.disko-install-menu;

  inherit (builtins)
    any
    attrValues
    getFlake
    isAttrs
    warn
    ;
  inherit (lib) types;
  inherit (lib.attrsets)
    filterAttrs
    mapAttrs'
    nameValuePair
    ;
  inherit (lib.lists) flatten singleton;
  inherit (lib.modules) mkForce mkIf;
  inherit (lib.options) literalExample mkEnableOption mkOption;
  inherit (lib.trivial) flip;

  flakesType = types.submodule (
    { config, ... }:
    {
      options = {
        offlineReference = mkOption {
          description = ''
            Offline flake reference of this entry.

            If set, the flake itself, all its inputs,
            and the dependencies of all its `nixosConfigurations`
            are cached into the resulting media
            to allow offline installing all configurations.
            You can limit which configurations are cached
            by setting {option}`.offlineConfigs`.

            This should either be:
            - a locked flake reference (as string)
            - the attrset of loaded flake
              (i.e. `self` or `inputs.*`)
            - `true` to use {option}`.reference` as a locked flake reference
            - `false` if this flake should not made available offline

            (When using `--impure`, you may use unlocked flake references as well.)
          '';
          type =
            with types;
            oneOf [
              bool
              str
              (raw // { description = "flake attrset"; })
            ];
          default = config.reference;
          example = literalExample "inputs.disko-install-menu";
        };
        # offlineHosts defined in ./menuConfig.nix
      };
    }
  );

  flakeDependencies =
    flake:
    let
      deps = (attrValues flake.inputs);
    in
    # string context from flake important for dependency resolution (i.e. do not use unsafeDiscardStringContext)
    # for more about string context, see:
    # - https://github.com/NixOS/nix/issues/6647
    # - https://nix.dev/manual/nix/2.32/language/string-context
    [ "${flake}" ] ++ flatten (map flakeDependencies deps);

  loadFlake =
    { reference, offlineReference, ... }:
    if offlineReference == false then
      null
    else if isAttrs offlineReference then
      offlineReference
    else
      getFlake (if offlineReference == true then reference else offlineReference);

  listHostDeps =
    host:
    flatten [
      (with host.config.system.build; [
        toplevel
        # disko scripts (esp. its dependencies)
        diskoScript
        formatScript
        mountScript
      ])
      # bootloader packages
      # required to build/confirm bootloader configuration
      (host.config.boot.loader.buildDependencies or (warn
        "disko-install-menu most probably not offline capable, missing boot.loader.buildDependencies on defaultHost config, install support module in host config to resolve"
        [ ]
      )
      )
      # see <nixpkgs/nixos/modules/config/system-path.nix>, config.system.path
      # (system.configurationRevision -> nixos-vesion -> environment.systemPackages)
      (pkgs.writeText "environment.extraSetup-dependencies" config.environment.extraSetup)
    ];

  listFlakeDeps =
    {
      reference,
      offlineReference,
      offlineHosts,
      ...
    }@flakeEntry:
    let
      flake = loadFlake flakeEntry;
      optimism = !(any (x: x) (attrValues offlineHosts));
      selectedHosts = flip filterAttrs flake.nixosConfigurations (
        name: _: offlineHosts.${name} or optimism
      );
      deps = flatten [
        (flakeDependencies flake)
        (map listHostDeps (attrValues selectedHosts))
      ];
    in
    if flake == null then [ ] else deps;

  listedFlakes = filterAttrs (_: x: x.enabled) cfg.listedFlakes;
in
{

  options.programs.disko-install-menu = {

    offlineCapable = mkEnableOption ''
      offline capability for this installer.

      Using this option either requires the flake definition
      of each flake in {option}`programs.disko-install-menu.listedFlakes.*.offlineReference` to be locked,
      or the nix option `--impure` to be set.
      `offlineReference` may also set to {variable}`false`
      to opt out that flake from offline caching.
      With {option}`programs.disko-install-menu.listedFlakes.*.offlineHosts`,
      one can select or deselect certain NixOS configurations
      from being cached for an offline installation.

      For more info about locked flake references, read the
      [nix manual on `builtins.getFlake`](https://nix.dev/manual/nix/latest/language/builtins.html#builtins-getFlake).

      In theory, this should allow disko-install-menu
      to install the selected configurations
      without needing to download additional sources or dependencies.

      This option is in **alpha status**,
      as due to its implementation,
      this may not *just work* for all configurations,
      feel free to report a bug in such cases.
      Nontheless, the installation should still succeed
      with access to the Internet / a suitable nix cache,
      and less files should be downloaded overall
    ''; # mkEnableOption -> dot at end is added

    listedFlakes = mkOption {
      type = types.attrsOf flakesType;
    };

  };

  config = mkIf cfg.offlineCapable {

    system.extraDependencies = flatten [

      # == config independent
      # no idea why those are actually required (has probably something to do with disko)
      (with pkgs; [
        makeBinaryWrapper
        jq.dev
      ])
      # pkgs.closureInfo (see <nixpkgs/pkgs/build-support/closure-info.nix>)
      (with pkgs; [
        coreutils
        jq
        stdenvNoCC
      ])
      # <nixpkgs/development/libraries/dbus/make-dbus-conf.nix>, nativeBuildInputs + buildInputs
      # (system.configurationRevision -> nixos-vesion -> environment.systemPackages
      #  -> system.path -> services.dbus.packages
      #  -> <nixpkgs/nixos/modules/services/system/dbus.nix>:configDir)
      (with pkgs; [
        libxslt.bin
        findXMLCatalogs
        # dbus package should already be loaded
      ])
      # <nixpkgs/lib/systemd-lib.nix>, generateUnits
      # (system.configurationRevision -> nixos-vesion -> environment.systemPackages
      #  -> system.path -> ? -> systemd.packages
      #  -> <nixpkgs/nixos/lib/systemd-lib.nix>:generateUnits)
      (with pkgs; [
        xorg.lndir
      ])

      # == config dependent
      (map listFlakeDeps (attrValues listedFlakes))

    ];

    programs.disko-install-menu = {
      options = {
        listedFlakes = flip mapAttrs' listedFlakes (
          n: v:
          let
            offlineRef = "${v.offlineReference}";
            onlyLocked = v.offlineReference == true || v.reference == offlineRef;
            # overwrite original entry if only offline / locked available
            name = if onlyLocked then n else "${n}_offline";
            val = mkForce {
              title = "${v.title} (offline)";
              reference = if onlyLocked then v.reference else offlineRef;
              inherit (v) offlineHosts;
              offlineOnly = !onlyLocked;
            };
          in
          nameValuePair name val
        );
      };
    };

  };

}
