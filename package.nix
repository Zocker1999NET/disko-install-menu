{
  lib,
  # build environment helpers
  replaceVarsWith,
  installShellFiles,
  # script dependencies
  bash,
  disko,
  fzf,
  nix,
  nixos-rebuild,
  nix-output-monitor,
  python3Minimal,
  smartmontools,
  util-linux,
  hostPreviewNix,
}:
let
  inherit (lib.strings) makeBinPath;
  inherit (lib.meta) getExe;
  name = "disko-install-menu";
in
replaceVarsWith {
  inherit name;

  src = ./setup.py;
  dir = "bin";
  isExecutable = true;

  # referred to by ./setup.py via @<var>@ notation
  replacements = {
    inherit name;
    runtimePython = getExe python3Minimal;
    path = makeBinPath [
      bash
      disko # for disko-install
      fzf
      nix
      nixos-rebuild
      nix-output-monitor
      python3Minimal
      smartmontools # for smartctl
      util-linux # for lsblk, fdisk
    ];
    inherit hostPreviewNix;
  };

  nativeBuildInputs = [ installShellFiles ];

  meta = {
    description = "Interactive installation menu for disko flake configurations";
    license = lib.licenses.mit; # SPDX-License-Identifier: MIT (so tools can find this reference)
    mainProgram = name;
  };
}
