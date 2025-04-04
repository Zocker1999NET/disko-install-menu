{
  lib,
  # build environment helpers
  substituteAll,
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
}:
let
  inherit (lib.strings) makeBinPath;
  inherit (lib.meta) getExe;
in
substituteAll {
  name = "disko-install-menu";

  src = ./setup.py;
  dir = "bin";
  isExecutable = true;

  # referred to by ./setup.py via @<var>@ notation
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
  hostPreviewNix = ./host-preview.nix;

  nativeBuildInputs = [ installShellFiles ];

  meta = {
    description = "Interactive installation menu for disko flake configurations";
    license = lib.licenses.mit; # SPDX-License-Identifier: MIT (so tools can find this reference)
    mainProgram = "disko-install-menu";
  };
}
