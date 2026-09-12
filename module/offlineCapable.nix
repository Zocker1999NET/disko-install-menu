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
    concatLists
    concatMap
    concatStringsSep
    getFlake
    isAttrs
    warn
    ;
  inherit (lib) types;
  inherit (lib.attrsets)
    filterAttrs
    mapAttrs'
    mapAttrsToList
    ;
  inherit (lib.lists) flatten singleton;
  inherit (lib.modules) mkForce mkIf;
  inherit (lib.options) literalExample mkEnableOption mkOption;
  inherit (lib.trivial) flip;

  flakesType = types.submodule (
    { config, ... }:
    {
      options = {

        offlineCapable = mkOption {
          description = ''
            Whether this flake entry must be prepared to become offline capable.

            Derived from {option}`.enabled` and {option}`.offlineReference`.
          '';
          type = types.bool;
          internal = true;
          readOnly = true;
          default = config.enabled && config.offlineReference != false;
        };
        onlineCapable = mkOption {
          description = ''
            Whether the online-capable version of this flake's entry must be preserved
            (as provided by ./menuConfig.nix).

            Derived from {option}`.enabled` and {option}`.offlineReference`.
          '';
          type = types.bool;
          internal = true;
          readOnly = true;
          default = config.enabled && config.offlineReference != true;
        };

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

  loadFlake =
    { reference, offlineReference, ... }:
    if offlineReference == false then
      null
    else if isAttrs offlineReference then
      offlineReference
    else
      getFlake (if offlineReference == true then reference else offlineReference);

  # recursively walk all inputs of flake and return a list of `{ path, storePath }`
  flakeInputs =
    flake:
    let
      walk =
        path: value:
        let
          own = [
            {
              inherit path;
              # string context from flake important for dependency resolution (i.e. do not use unsafeDiscardStringContext)
              # for more about string context, see:
              # - https://github.com/NixOS/nix/issues/6647
              # - https://nix.dev/manual/nix/2.32/language/string-context
              storePath = "${value}";
            }
          ];
          sub = concatLists (mapAttrsToList (name: walk "${path}/${name}") (value.inputs or { }));
        in
        own ++ sub;
    in
    concatLists (mapAttrsToList walk (flake.inputs or { }));

  # the hacky way of how to effectively override all inputs of a flake without using `--override-input` flags
  # which is unsupported by some NixOS tooling like `nixos-install` & so `disko-install`:
  # - copy the flake's source into the derivation output
  # - drop its original flake.lock
  # - re-lock all inputs against hardcoded store paths made available offline
  #
  # advantages of this approach:
  # -> resulting derivation is a self-contained flake with all inputs available offline,
  #    and so can definitely be evaluated offline & without any `--override-input` flags
  # -> makes disko-install-menu module support using using a flake with followed (=overriden) inputs
  #    - otherwise its flake.lock would require the original flake's input paths
  #    - making overriding its inputs with follows impossible,
  #    - and without parsing flake.lock + builtins.getFlake, we cannot provide the original inputs as extraDependencies,
  #    - thus breaking offline evaluation of the flake
  buildOfflineFlake =
    flake:
    let
      inputs = flakeInputs flake;
      overrideArgs = concatStringsSep " " (
        concatMap ({ path, storePath, ... }: [
          "--override-input"
          path
          "${storePath}"
        ]) inputs
      );
    in
    pkgs.runCommand "offline-flake"
      {
        nativeBuildInputs = with pkgs; [
          nix
        ];
      }
      # workarounds s.t. `nix flake lock` inside a derivation works without recursive-nix experimental feature
      ''
        # nix needs its state dirs to be writable, i.e. redirect them to temporary locations
        # (see https://github.com/NixOS/nix/issues/10385)
        export NIX_STATE_DIR=$(mktemp -d)
        export NIX_LOCALSTATE_DIR=$(mktemp -d)
        export NIX_LOG_DIR=$(mktemp -d)

        # when using path:/nix/store/… flakes, nix wants to persist fetcher metadata in its cache dir
        export NIX_CACHE_HOME=$(mktemp -d)
        export XDG_CACHE_HOME=$(mktemp -d)

        # use a chroot local store for evaluation so nix does not conflict with readonly /nix/store
        nix_tmp_store=$(mktemp -d)

        nix-flake-lock() {
          nix \
            --extra-experimental-features 'nix-command flakes' \
            --offline \
            flake lock \
            --eval-store "local?root=$nix_tmp_store" \
            "$@"
        }

        # copy original flake source & make writable again
        cp --recursive ${flake} $out
        chmod --recursive u+w $out
        cd $out

        # fully re-lock & also make locking fail when not all inputs are overridden
        rm --force --verbose ./flake.lock

        # lock against hardcoded store paths -> are stored in flake.lock -> become "runtime dependencies" of the flake
        nix-flake-lock ${overrideArgs}

        # re-lock again to resolve any follows now (not required for success, just optimization s.t. this happens not on every evaluation of the flake)
        nix-flake-lock
      '';

  listHostDeps =
    host:
    let
      # use host.pkgs in case config uses different nixpkgs than installer
      inherit (host) pkgs;
    in
    flatten [

      # == config independent
      (with pkgs; [

        # no idea why those are actually required (has probably something to do with disko)
        makeBinaryWrapper
        jq.dev

        # pkgs.closureInfo (see <nixpkgs/pkgs/build-support/closure-info.nix>)
        coreutils
        jq
        stdenvNoCC

        # <nixpkgs/development/libraries/dbus/make-dbus-conf.nix>, nativeBuildInputs + buildInputs
        # (system.configurationRevision -> nixos-version -> environment.systemPackages
        #  -> system.path -> services.dbus.packages
        #  -> <nixpkgs/nixos/modules/services/system/dbus.nix>:configDir)
        libxslt.bin
        findXMLCatalogs
        # dbus package should already be loaded

        # <nixpkgs/lib/systemd-lib.nix>, generateUnits
        # (system.configurationRevision -> nixos-version -> environment.systemPackages
        #  -> system.path -> ? -> systemd.packages
        #  -> <nixpkgs/nixos/lib/systemd-lib.nix>:generateUnits)
        xorg.lndir

      ])

      # == config dependent

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
      # (system.configurationRevision -> nixos-version -> environment.systemPackages)
      (pkgs.writeText "environment.extraSetup-dependencies" host.config.environment.extraSetup)
      # system.checks because those are required for changes in .toplevel
      # (system.configurationRevision -> nixos-version -> environment.systemPackages
      #  -> system.build.toplevel)
      host.config.system.checks

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
        (singleton "${buildOfflineFlake flake}")
        (map listHostDeps (attrValues selectedHosts))
      ];
    in
    if flake == null then [ ] else deps;

  listedFlakes = filterAttrs (_: x: x.offlineCapable) cfg.listedFlakes;
in
{

  _class = "nixos";

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

    assertions = concatLists [
      (flip mapAttrsToList listedFlakes (
        name:
        { reference, offlineReference, ... }:
        {
          assertion = reference != offlineReference;
          message = concatStringsSep " " [
            "programs.disko-install-menu.listedFlakes.${name}:"
            "declaring offlineCapable flake entry with .reference == .offlineReference is not supported,"
            "as it produces one non-working & one working entry in the menu,"
            "use .offlineReference = true instead"
          ];
        }
      ))
    ];

    system.extraDependencies = flatten (map listFlakeDeps (attrValues listedFlakes));

    programs.disko-install-menu = {
      options = {
        listedFlakes = flip mapAttrs' listedFlakes (
          n:
          {
            title,
            offlineHosts,
            onlineCapable,
            ...
          }@flakeEntry:
          {
            # overwrite original entry if only offline / locked available
            name = if onlineCapable then "${n}_offline" else n;
            value = mkForce {
              title = "${title} (offline)";
              # loadFlake cannot return null cause we filter for offlineCapable flakes only
              reference = "${buildOfflineFlake (loadFlake flakeEntry)}";
              inherit offlineHosts;
              offlineOnly = true;
            };
          }
        );
      };
    };

  };

}
