#! @runtimePython@

from __future__ import annotations

import argparse
from collections.abc import (
    Iterable,
    Mapping,
    Sequence,
)
from contextlib import contextmanager
from dataclasses import (
    dataclass,
    field,
)
from enum import (
    Enum,
    auto,
)
import errno
import fcntl
from functools import (
    cached_property,
    wraps,
)
import hashlib
import json
from multiprocessing.connection import (
    Client,
    Listener,
)
import os
from pathlib import Path
import random
import shlex
import subprocess
import sys
from threading import (
    Thread,
)
import time
from typing import (
    Any,
    Callable,
    Generator,
    IO,
    Literal,
    NewType,
    NoReturn,
    ParamSpec,
    Protocol,
    Self,
    assert_never,
    cast,
)


APP_NAME = "@name@"
if APP_NAME.startswith("@"):
    APP_NAME = "disko-install-menu"

HOST_PREVIEW_NIX = "@hostPreviewNix@"
if HOST_PREVIEW_NIX.startswith("@"):
    HOST_PREVIEW_NIX = "./host-preview.nix"


nix_pkg_path = "@path@"
if not nix_pkg_path.startswith("@"):
    os.environ["PATH"] = f"{nix_pkg_path}:{os.environ['PATH']}"


# TODO convert those to Settings class, which gets passed along
#   or alt: pack everything into an App class, which contains those settings


DEBUG_MODE = True

DEFAULT_FLAKE = "github:Zocker1999NET/server/deployed"
DEFAULT_HOST = "empty"

DISKO_INSTALL_FLAGS = []
# TODO read from system config (because broken on some machines -> make it more dynamic)
WRITE_EFI_BOOT_ENTRIES: bool | None = True  # None = depending on selected config


CONFIG_PATH = Path(os.getenv("CONFIG_PATH", f"/etc/{APP_NAME}/config"))


# === lib


def lazy_combine_tristate(
    fun: Callable[P, Generator[bool | None, None, bool]]
) -> Callable[P, bool]:
    def wrapper(*args: P.args, **kwargs: P.kwargs) -> bool:
        gen = fun(*args, **kwargs)
        try:
            while True:
                val = next(gen)
                if val is not None:
                    return val
        except StopIteration as e:
            return e.value

    return wrapper


# === initialization


def main():
    args = parse_args()
    read_config()
    if args.preview_call:
        return MenuSelection.render_preview(*args.preview_call)
    mode_select()


def read_config():
    global DEBUG_MODE, DEFAULT_FLAKE, DEFAULT_HOST, DISKO_INSTALL_FLAGS, WRITE_EFI_BOOT_ENTRIES
    if not CONFIG_PATH.is_file():
        raise RuntimeError(f"missing configuration file at {str(CONFIG_PATH)!r}")
    with CONFIG_PATH.open("r") as fd:
        data = json.load(fd)
    DEBUG_MODE = data.get("debugMode", False)
    DEFAULT_FLAKE = data["defaultFlake"]
    DEFAULT_HOST = data["defaultHost"]
    DISKO_INSTALL_FLAGS = data.get("diskoInstallFlags", list())
    WRITE_EFI_BOOT_ENTRIES = data.get("writeEfiBootEntries", None)


def parse_args():
    parser = argparse.ArgumentParser(prog=APP_NAME)
    parser.add_argument(
        "--preview-call",
        nargs=2,  # sub-args are passed to function render_preview(…)
        help="used internally only (to generate previews for fzf)",
    )
    return parser.parse_args()


# === setup menus


def mode_select():
    while True:
        menu = MenuSelection.new(
            MenuDesign(border_label="what do you want to do?"),
            SimpleMenuOption(
                "install",
                "install / repair NixOS",
                "select a specific configuration\n(i.e. from a given flake)\nto install on this device\n\nyou may also mount an existing configuration and so fix & update it\nsome choices require network connectivity",
            ),
            SimpleMenuOption(
                "shell",
                "open shell",
                "open root shell\nfor advanced users\non exit you will return to this menu\n\ne.g. for setting up network connectivity\n\npro tip: you may also jump to another virtual console with CTRL+ALT+F2",
            ),
            SimpleMenuOption(
                "poweroff",
                "shutdown",
                "shutdown this computer",
            ),
            SimpleMenuOption(
                "reboot",
                "reboot",
                "reboot this computer",
            ),
            SimpleMenuOption(
                "reboot --firmware-setup",
                "reboot into UEFI firmware settings",
                "reboot into UEFI settings\n(i.e. BIOS/mainboard/firmware settings)\n\nmay not work on all computers\ndespite being indicated as supported",
            ),
        )
        sel = menu.show_selection()
        if sel is None:
            if DEBUG_MODE:
                return
            continue
        if sel.tag == "install":
            install_select()
            continue
        if sel.tag == "shell":
            open_shell()
            continue
        break
    if "poweroff" in sel.tag or "reboot" in sel.tag:
        call("systemctl " + sel.tag)
        return
    raise_invalid_choice(sel)


def install_select():
    while True:
        menu = MenuSelection.new(
            MenuDesign(border_label="what do you want to do?", header="install …"),
            SimpleMenuOption(
                "default_flake",
                f"from flake {DEFAULT_FLAKE}",
                f"select host configuration from flake:\n{DEFAULT_FLAKE}\n\nprobably requires network connectivity",
            ),
            SimpleMenuOption(
                "flake_input",
                "from flake URL",
                "prompt for flake URL\nto select NixOS configuration from\n\nrequires network connectivity",
            ),
            SimpleMenuOption(
                "default_host",
                "default target",
                "install config preselected for unattended installation:",
                # TODO render config preview
            ),
            SimpleMenuOption(
                "return",
                "<return>",
                "go back to previous config",
            ),
        )
        sel = menu.show_selection()
        if sel is None or sel.tag == "return":
            return
        if sel.tag == "flake_input":
            user_flake = flake_input()
            if user_flake is not None:
                host_select(user_flake)
            continue
        if sel.tag == "default_flake":
            host_select(DEFAULT_FLAKE)
            continue
        if sel.tag == "default_host":
            host_menu(ConfigSource(DEFAULT_FLAKE, DEFAULT_HOST))
            continue
        break
    raise_invalid_choice(sel)


def flake_input() -> str | None:
    print("> insert flake url to retrieve NixOS configurations from")
    print("for example:")
    examples = (
        "github:NixOS/nixpkgs  (albeit that contains no configs)",
        f"{DEFAULT_FLAKE}  (configured default)",
    )
    print("\n".join(f"- {line}" for line in examples))
    print("(submit empty input or CTRL+D to return back to menu)")
    print()
    try:
        user_input = input("flake> ")
    except EOFError:
        return None
    if user_input == "":
        return None
    return user_input


def host_select(flake: str):
    print("collection information for all host configurations, this may take a while …")
    options = [
        # TODO preview_cmd for better performance
        SimpleMenuOption(
            "host",
            host,
            ConfigSource(flake, host).host_preview,
        )
        for host in list_nixos_configs(flake)
    ]
    options.append(
        SimpleMenuOption("return", "<return>", "go back to the previous menu"),
    )
    print("(finished collecting host configurations)")
    while True:
        menu = MenuSelection.new(
            MenuDesign(
                border_label="select host configurations for install",
                header=flake,
                prompt="host> ",
            ),
            *options,
        )
        sel = menu.show_selection()
        if sel is None or sel.tag == "return":
            return
        if sel.tag == "host":
            host_menu(ConfigSource(flake, sel.name))
            continue
        break
    raise_invalid_choice(sel)


def host_menu(config: ConfigSource):
    while True:
        menu = MenuSelection.new(
            MenuDesign(border_label="what do you want to do?", header="install …"),
            SimpleMenuOption(
                "install",
                "install cleanly",
                "FORMAT disks according to disko configuration\nand install NixOS system from configuration.\n\nIn the end, this will have wiped all disks\nyou will select in the upcoming menus.",
            ),
            SimpleMenuOption(
                "upgrade",
                "upgrade installation",
                "Attempt to mount disks according to disko configuration\nand to upgrade NixOS system from configuration.\n\nThis will try to build a new generation to the existing system,\nwhich could be useful if the system became completely unbootable\nor if you want to update the system without being offline.\n\nThis requires that all disks are exactly partitioned\nas defined in the NixOS disko configuration,\notherwise your system might become more broken than before!",
            ),
            SimpleMenuOption(
                "enter",
                "enter installation",
                "Attempt to mount disks according to disko configuration\nand to enter the NixOS system via nixos-enter.\n\nThis step is comparable to chroot, but more adapted to NixOS quirks.\n\nThis requires that all disks are exactly partitioned\nas defined in the NixOS disko configuration,\notherwise your system might become more broken than before!",
            ),
            SimpleMenuOption(
                "repl",
                "repl",
                "Gives you insight in the selected NixOS configuration via nixos-rebuild repl.",
            ),
            SimpleMenuOption(
                "return",
                "<return>",
                "go back to previous config",
            ),
        )
        sel = menu.show_selection()
        if sel is None or sel.tag == "return":
            return
        if sel.tag in {"install", "upgrade", "enter"}:
            host_install_menus(InstallPlan(config, InstallMode.from_name(sel.tag)))
            continue
        if sel.tag == "repl":
            call(["nixos-rebuild", "--flake", config.short_spec, "repl"])
            continue
        break
    raise_invalid_choice(sel)


def host_install_menus(plan: InstallPlan) -> None:
    plan = ask_for_missing_disks(plan)
    if plan is None:
        return
    on_success = action_on_success(plan)
    if on_success is None:
        return
    plan = confirm_menu(plan)
    if plan is None:
        return
    print(f"[{APP_NAME}] Start Installation")
    if plan.execute_install() is not True:
        print(f"[{APP_NAME}] Installation Failed!")
        open_shell()
        return
    print(f"[{APP_NAME}] Installation Completed Successfully 🎉")
    success_cmd = on_success.cmd
    if success_cmd is None:
        press_any_key("to return back to install menu")
        return
    print("issue finalization action:")
    call(success_cmd)


def confirm_menu(plan: InstallPlan) -> InstallPlan | None:
    while True:
        menu = MenuSelection.new(
            MenuDesign(border_label="confirm installation"),
            SimpleMenuOption(
                "install",
                "<< INSTALL NOW >>",
                f"this will {plan.mode.action_on_disk} following disks:\n\n{plan.disk_map_preview}\n\nand apply following config:\n\n{plan.config.host_preview}",
            ),
            SimpleMenuOption(
                "writeEfiBootEntries",
                f"writeEfiBootEntries = {plan.will_write_efi_boot_entries}",
                "submit to toggle\nwhether EFI boot entries will be written into EFI variables",
            ),
            SimpleMenuOption(
                "return",
                "<< return >>",
                "abort installation and go back to host selection",
            ),
        )
        sel = menu.show_selection()
        if sel is None or sel.tag == "return":
            return None
        if sel.tag == "install":
            return plan
        if sel.tag == "writeEfiBootEntries":
            plan.writeEfiBootEntries = not plan.will_write_efi_boot_entries
    raise_invalid_choice(sel)


def action_on_success(plan: InstallPlan) -> CompletionAction | None:
    while True:
        menu = MenuSelection.new(
            MenuDesign(border_label=plan.config.short_spec),
            SimpleMenuOption(
                "shutdown",
                "shutdown",
                "shutdown this computer\nafter successful installation",
            ),
            SimpleMenuOption(
                "reboot",
                "reboot",
                "reboot this computer\nafter successful installation\n\nThe next system booted depends on the configuration of your firmware.\nDo not forget to remove this installation media,\nas booting it may trigger an unattended installation WIPING data!\n(Only wizards may ignore this warning.)",
            ),
            SimpleMenuOption(
                "firmware",
                "reboot into UEFI firmware setup",
                "reboot into UEFI firmware\nafter successful installation\n\nDespite being indicated as supported, this may not work on all computers.\nMeaning that the same WARNING for REBOOT apply here!",
            ),
            SimpleMenuOption(
                "menu",
                "return back to menu",
                "return back into host menu\nafter successful installation\n\nThis allows you e.g. to apply custom steps after the installation.",
            ),
            SimpleMenuOption(
                "return",
                "<return>",
                "go back to host selection (immediately)",
            ),
        )
        sel = menu.show_selection()
        if sel is None or sel.tag == "return":
            return None
        return CompletionAction.from_name(sel.tag)
    raise_invalid_choice(sel)


def ask_for_missing_disks(plan: InstallPlan) -> InstallPlan:
    for disk_name in plan.config.list_disko_disks():
        if disk_name in plan.disk_map:
            continue
        disk_path = select_disk(plan, disk_name)
        if disk_path is None:
            return None
        plan.disk_map[disk_name] = disk_path
    return plan


def select_disk(
    plan: InstallPlan,
    disk_name: DiskName,
) -> DiskPath | None:
    options = [
        SimpleMenuOption(
            f"disk:{disk.path}",
            disk.description,
            disk.preview_disk(),
        )
        for disk in DiskInfo.list_all()
    ]
    options.append(
        SimpleMenuOption(
            "manual",
            "<manual input>",
            "input custom path to disk\n\nWARNING: for advanced users only\nno further checks are applied",
        ),
    )
    options.append(
        SimpleMenuOption(
            "return",
            "<return>",
            "abort disk selection",
        ),
    )
    while True:
        menu = MenuSelection.new(
            MenuDesign(
                border_label=f"select disk for config: {disk_name}",
                header=DiskInfo.description_header,
            ),
            *options,
        )
        sel = menu.show_selection()
        if sel is None or sel.tag == "return":
            return None
        if sel.tag == "manual":
            return manual_disk_input(plan, disk_name)
        if sel.tag.startswith("disk:"):
            return DiskPath(sel.tag[5:])
        break
    raise_invalid_choice(sel)


def manual_disk_input(plan: InstallPlan, disk_name: DiskName) -> DiskPath | None:
    search_dirs = [Path("/dev")]
    search_dirs.extend(path for path in Path("/dev/disk").iterdir() if path.is_dir())
    for search in search_dirs:
        call(["ls", str(search)], safe=True)
    print()
    print(f"please insert disk for config: {disk_name}")
    print("  full path is required, e.g. /dev/sda")
    try:
        user_input = input(f"{disk_name}> ")
    except EOFError:
        return None
    if user_input == "":
        return None
    return user_input


def press_any_key(reason: str = "to continue") -> None:
    print(f"press enter {reason} …")
    input()


# === installation processing helpers


def open_shell() -> None:
    print("> opening login shell, exit shell to return to install menu")
    call("bash -l", safe=True, echo=False)


@dataclass
class InstallPlan:
    # ones which should not be changed
    config: ConfigSource
    mode: InstallMode
    # ones which can be changed
    disk_map: Mapping[DiskName, DiskPath] = field(default_factory=dict)
    writeEfiBootEntries: bool | None = None

    def execute_install(self) -> Literal[True] | subprocess.CalledProcessError:
        try:
            call(
                self.pre_generation_cmd(),
                safe=True,  # is non-destructive & part of debugging
            )
            call(
                self.installation_cmd(),
                safe=True,  # i.e. already checks for debug mode
            )
        except subprocess.CalledProcessError as e:
            return False
        return True

    def pre_generation_cmd(self) -> Sequence[str] | None:
        """can be executed before installation_cmd to have a fancier progress display

        not required to be executed at all
        """
        if not self.mode.utilizes_prebuild:
            return None
        return [
            "nom",
            "build",
            "--extra-experimental-features",
            "nix-command flakes",
            "-L",
            "--show-trace",
            "--no-link",
            f"{self.config.flake_spec}.config.system.build.toplevel",
        ]

    def installation_cmd(self) -> Sequence[str]:
        disko_args = ["disko-install", "--flake", self.config.short_spec]
        if DEBUG_MODE:
            disko_args.append("--dry-run")
        disko_args.extend(DISKO_INSTALL_FLAGS)
        if self.will_write_efi_boot_entries:
            disko_args.append("--write-efi-boot-entries")
        for name, path in self.disk_map.items():
            disko_args.extend(("--disk", name, path))
        disko_args.extend(self.mode.disko_args)
        return disko_args

    @property
    def disk_map_preview(self) -> str:
        return "\n".join(f"{name} -> {path}" for name, path in self.disk_map.items())

    @property
    @lazy_combine_tristate
    def will_write_efi_boot_entries(self) -> bool:
        yield self.writeEfiBootEntries
        yield WRITE_EFI_BOOT_ENTRIES
        return self.__internal_can_touch_efi_variables

    @cached_property
    def __internal_can_touch_efi_variables(self) -> bool:
        return self.config.get_option("boot.loader.efi.canTouchEfiVariables")


class CompletionAction(Enum):
    SHUTDOWN = auto()
    REBOOT = auto()
    FIRMWARE = auto()
    MENU = auto()

    @property
    def cmd(self) -> Sequence[str] | None:
        match self:
            case CompletionAction.SHUTDOWN:
                return ["systemctl", "poweroff"]
            case CompletionAction.REBOOT:
                return ["systemctl", "reboot"]
            case CompletionAction.SHUTDOWN:
                return ["systemctl", "reboot", "--firmware-setup"]
            case CompletionAction.MENU:
                return None
        assert_never()

    @staticmethod
    def from_name(name: str) -> CompletionAction:
        name = name.lower()
        if name == "shutdown":
            return CompletionAction.SHUTDOWN
        if name == "reboot":
            return CompletionAction.REBOOT
        if name == "firmware":
            return CompletionAction.FIRMWARE
        if name == "menu":
            return CompletionAction.MENU
        raise RuntimeError(f"unknown CompletionAction: {name!r}")


class InstallMode(Enum):
    ENTER = auto()
    INSTALL = auto()
    UPGRADE = auto()

    @property
    def utilizes_prebuild(self) -> bool:
        return self != InstallMode.ENTER

    @property
    def disko_args(self) -> Sequence[str]:
        match self:
            case InstallMode.ENTER:
                raise NotImplementedError("InstallMode.ENTER not supported yet")
            case InstallMode.INSTALL:
                return ("--mode", "format")
            case InstallMode.UPGRADE:
                return ("--mode", "mount")
        assert_never()

    @property
    def action_on_disk(self) -> str:
        match self:
            case InstallMode.ENTER:
                return "enter"
            case InstallMode.INSTALL:
                return "WIPE"
            case InstallMode.UPGRADE:
                return "upgrade"
        assert_never()

    @staticmethod
    def from_name(name: str) -> InstallMode:
        name = name.lower()
        if name == "enter":
            return InstallMode.ENTER
        if name == "install":
            return InstallMode.INSTALL
        if name == "upgrade":
            return InstallMode.UPGRADE
        raise RuntimeError(f"unknown InstallMode: {name!r}")


@dataclass(
    frozen=True,
)
class ConfigSource:
    flake: str
    host: str

    def list_disko_disks(self) -> Sequence[DiskName]:
        raw_data = self.eval(
            attribute="config.disko.devices.disk",
            apply="a: with builtins; toJSON (attrNames a)",
        )
        return json.loads(raw_data)

    @cached_property
    def host_preview(self) -> str:
        with Path(HOST_PREVIEW_NIX).open("r") as fd:
            preview_gen = fd.read()
        return self.eval(apply=preview_gen).rstrip("\r\n")

    def get_option(self, option: str) -> Any:
        "requires the option value to be generally JSON compatible"
        return json.loads(self.eval(f"config.{option}", "builtins.toJSON"))

    def eval(self, attribute: str | None = None, apply: str | None = None) -> str:
        args = [
            "nix",
            "eval",
            "--raw",
            self.flake_spec if attribute is None else f"{self.flake_spec}.{attribute}",
        ]
        if apply is not None:
            args.extend(("--apply", apply))
        return call_for_info(args, stderr_suppress=True)

    @property
    def flake_spec(self) -> str:
        return f'{self.flake}#nixosConfigurations."{self.host}"'

    @property
    def short_spec(self) -> str:
        return f"{self.flake}#{self.host}"


DiskName = NewType("DiskName", str)
"name of disk in a disko config"
DiskPath = NewType("DiskPath", str)
"path to a block device of a disk"


@dataclass(frozen=True)
class DiskInfo:
    name: str
    size: str
    "for humans, e.g. 361g"
    model: str
    serial: str
    wwn: str

    @staticmethod
    def list_all() -> Iterable[DiskInfo]:
        raw_data = call_for_info(
            [
                "lsblk",
                "--nodeps",
                "--json",
                "--output-all",
            ]
        )
        json_data = json.loads(raw_data)
        for dev_type, devices in json_data.items():
            for disk_data in devices:
                yield DiskInfo(
                    name=disk_data["name"],
                    size=disk_data["size"],
                    model=disk_data["model"],
                    serial=disk_data["serial"],
                    wwn=disk_data["wwn"],
                )

    def preview_disk(self) -> str:
        return "".join(
            (
                call_for_info(["fdisk", "--list", self.path], ignore_errors=True),
                "\n",  # empty line as separation
                call_for_info(["lsblk", "--fs", self.path], ignore_errors=True),
                call_for_info(["smartctl", "--info", self.path], ignore_errors=True),
            )
        )

    @property
    @staticmethod
    def description_header(self) -> str:
        return "name - size - model - serial - wwn"

    @property
    def description(self) -> str:
        return f"{self.name} - {self.size} - {self.model} - {self.serial} - {self.wwn}"

    @property
    def path(self) -> DiskPath:
        return DiskPath(f"/dev/{self.name}")


def list_nixos_configs(flake: str) -> Sequence[str]:
    raw_data = call_for_info(
        [
            "nix",
            "eval",
            "--raw",
            f"{flake}#nixosConfigurations",
            "--apply",
            'a: with builtins; concatStringsSep "\\n" (attrNames a) + "\\n"',
        ],
        stderr_suppress=True,
    )
    return sorted(
        raw_data.rstrip("\r\n").splitlines(),
        key=fqdn_key,
    )


def fqdn_key(fqdn):
    # Split FQDN into labels and reverse the labels
    labels = fqdn.strip(".").split(".")[::-1]
    return (len(labels), labels)


def call_for_info(
    cmd: Sequence[str],
    stderr_suppress: bool = False,
    ignore_errors: bool = False,
) -> str:
    proc = subprocess.run(
        ["/usr/bin/env"] + list(cmd),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE if stderr_suppress else None,
        text=True,
    )
    if ignore_errors:
        return (
            proc.stdout
            if stderr_suppress
            else "\n".join(t for t in (proc.stdout, proc.stderr) if t)
        )
    if stderr_suppress and proc.returncode != 0:
        print(proc.stderr, file=sys.stderr)
    proc.check_returncode()
    return proc.stdout


def call(
    cmd: Sequence[str] | str | None,
    safe: bool = False,
    echo: bool = True,
) -> None:
    if cmd is None:
        return None
    if isinstance(cmd, str):
        cmd = shlex.split(cmd)
    else:
        cmd = list(iter(cmd))
    if DEBUG_MODE and not safe:
        print("[DEBUG] + " + shlex.join(cmd))
        print("[DEBUG] (sleep some seconds for you to read this)")
        time.sleep(3)
        return
    if echo:
        print("+ " + shlex.join(cmd))
    subprocess.check_call(["/usr/bin/env"] + cmd)


P = ParamSpec("P")


# === menu rendering


def raise_invalid_choice(data: MenuOption):
    raise Exception(f"invalid option selected: {data!r}")


@dataclass(
    frozen=True,
)
class MenuSelection:
    design: MenuDesign
    options: Mapping[str, MenuOption]

    @staticmethod
    def new(design: MenuDesign, *options: MenuOption) -> MenuSelection:
        return MenuSelection(
            design,
            {o.name: o for o in options},
        )

    def show_selection(self) -> MenuOption | None:
        with MenuSelection.__preview_listener(self) as cmd:
            fzf_args = [
                "/usr/bin/env",
                "fzf",
                "--layout=reverse",
                "--tiebreak=index",
                "--border=rounded",
                "--margin=1",
                "--padding=1",
                "--no-info",
                f"--preview={cmd}",
            ]
            fzf_args.extend(self.design.fzf_args)
            proc = subprocess.Popen(
                fzf_args,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                text=True,
            )
            stdout, _ = proc.communicate("\n".join(self.options.keys()) + "\n")
        if proc.returncode in {1, 130}:
            return None
        elif proc.returncode != 0:
            raise subprocess.CalledProcessError(
                proc.returncode,
                fzf_args,
                stdout,
            )
        name = stdout.rstrip("\r\n")
        selection = self.options.get(name)
        if selection is None:
            raise RuntimeError(
                f"should not happen, please report: unknown option selected: {name!r}"
            )
        return selection

    @staticmethod
    def render_preview(address: str, name: str) -> NoReturn:
        """handler for --preview-call, taking its arguments"""
        conn = Client(family="AF_UNIX", address=address)
        conn.send(name)
        option = cast(MenuOption | None, conn.recv())
        conn.close()
        if option is None:
            print(
                f"should not happen, please report:\nno preview available for\n{name!r}"
            )
            sys.exit(1)
        # TODO adapt preview text to size of preview window (given via environment variables)
        option.output_preview()

    @staticmethod  # required for contextmanager to work
    @contextmanager
    def __preview_listener(selection: MenuSelection) -> Iterable[str]:
        exit_code = random.randbytes(32)
        listener = Listener(family="AF_UNIX")
        thread = Thread(
            target=selection.__provide_listener,
            args=(listener, exit_code),
            daemon=True,
        )
        thread.start()
        try:
            yield shlex.join(
                (
                    sys.executable,
                    sys.argv[0],
                    "--preview-call",
                    listener.address,
                )
            ) + " {}"  # placeholder for fzf, required to be unescaped
        finally:
            conn = Client(family="AF_UNIX", address=listener.address)
            conn.send(exit_code)
            if exit_code != conn.recv():
                raise RuntimeError(
                    "multiprocess Listener thread did not answer with correct exit code!"
                )
            conn.close()
            thread.join()

    def __provide_listener(self, listener: Listener, exit_code: bytes) -> NoReturn:
        while True:
            conn = listener.accept()
            name = conn.recv()
            if name == exit_code:
                conn.send(exit_code)
                conn.close()
                listener.close()
                return
            conn.send(self.options.get(name))
            conn.close()


@dataclass(
    frozen=True,
)
class MenuDesign:
    border_label: str
    header: str | None = None
    prompt: str | None = None

    @property
    def fzf_args(self) -> Sequence[str]:
        return tuple(
            f"{key}={val}" for key, val in self.__fzf_args().items() if val is not None
        )

    def __fzf_args(self) -> Mapping[str, str | None]:
        border_label = self.border_label
        if DEBUG_MODE:
            border_label = f"[DEBUG] {border_label} [DEBUG]"
        return {
            "--border-label": border_label,
            "--header": self.header,
            "--prompt": self.prompt,
        }


class MenuOption(Protocol):

    @property
    def tag(self) -> str: ...

    @property
    def name(self) -> str: ...

    def output_preview(self) -> NoReturn: ...


@dataclass(
    frozen=True,
)
class SimpleMenuOption:
    tag: str
    name: str
    description: str

    def output_preview(self) -> NoReturn:
        print(self.description)
        sys.exit(0)


@dataclass(
    frozen=True,
)
class PreviewMenuOption:
    tag: str
    name: str
    preview_cmd: str

    def output_preview(self) -> NoReturn:
        # TODO how to get "global" tmp_dir
        CachedCall(tmp_dir, self.preview_cmd).retrieve().reproduce()


# === cached calling


@dataclass(
    frozen=True,
)
class CallReturn:
    return_code: int
    stdout: str
    stderr: str

    @staticmethod
    def from_call(cmd: Sequence[str]) -> CallReturn:
        "will forget about timing of stdout & stderr messages"
        proc = subprocess.run(
            cmd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        return CallReturn(
            return_code=proc.returncode,
            stdout=proc.stdout,
            stderr=proc.stderr,
        )

    def reproduce(self, suppress_stderr: bool = False) -> NoReturn:
        "will not be able to reproduce timing of stdout & stderr messages"
        print(self.stdout, end="", file=sys.stdout)
        if not suppress_stderr or result.return_code != 0:
            print(self.stderr, end="", file=sys.stderr)
        sys.exit(self.return_code)

    @staticmethod
    def from_json_str(json_data: str) -> CallReturn:
        return CallReturn.from_json_struct(json.loads(json_data))

    def to_json_str(self) -> str:
        return json.dumps(self.to_json_struct())

    @staticmethod
    def from_json_io(fp: IO[str]) -> CallReturn:
        return CallReturn.from_json_struct(json.load(fp))

    def to_json_io(self, fp: IO[str]) -> None:
        json.dump(self.to_json_struct(), fp)

    @staticmethod
    def from_json_struct(data: Any) -> CallReturn:
        return CallReturn(
            return_code=data["return_code"],
            stdout=data["stdout"],
            stderr=data["stderr"],
        )

    def to_json_struct(self) -> Any:
        return {
            "return_code": self.return_code,
            "stdout": self.stdout,
            "stderr": self.stderr,
        }


@dataclass(
    frozen=True,
)
class CachedCall:
    tmp_dir: Path
    cmd: Sequence[str]

    def retrieve(self) -> CallReturn:
        if self.tmp_file.exists():
            return self.__from_cache()
        return self.__try_populate_cache()

    def __try_populate_cache(self) -> CallReturn:
        with self.tmp_file.open("w") as fd:
            try:
                fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError as e:
                if e.errno in {errno.EACCES, errno.EAGAIN}:
                    # assume getting lock failed -> other process will populate cache
                    return self.__from_cache()
                raise e
            # we won populating the cache
            result = self.__generate()
            result.to_json_io(fd)
            return result
            # should auto-unlock when fd is closed

    def __from_cache(self) -> CallReturn:
        with self.tmp_file.open("r") as fd:
            fcntl.lockf(fd, fcntl.LOCK_SH)  # block until LOCK_EX is away
            return CallReturn.from_json_io(fd)
            # should auto-unlock when fd is closed

    def __generate(self) -> CallReturn:
        return CallReturn.from_call(self.cmd)

    @cached_property
    def tmp_file(self) -> Path:
        return (
            self.tmp_dir
            / hashlib.sha3_256(shlex.join(self.cmd).encode("utf-8")).hexdigest()
        )


if __name__ == "__main__":
    main()
