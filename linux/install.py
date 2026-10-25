"""Install launchers referencing this source checkout; preserve existing launchers."""

import os
from pathlib import Path
import shutil
import stat
import time

from uniconnect.i18n import Translator


def is_uniconnect_cli(target, current):
    """Return true only for a symlink to this or another UniConnect checkout's cmux."""
    if not target.is_symlink():
        return False
    try:
        resolved = target.resolve(strict=True)
    except OSError:
        return False
    if resolved == current.resolve():
        return True
    package = resolved.parent / "uniconnect"
    return (resolved.name == "cmux" and package.is_dir()
            and (package / "cli.py").is_file())


def backup_target(target, backup):
    """Preserve a prior launcher, keeping symlinks pointed at the same target."""
    backup.mkdir(parents=True, mode=0o700, exist_ok=True)
    destination = backup / target.name
    if target.is_symlink():
        destination.symlink_to(target.resolve(strict=False))
    else:
        shutil.copy2(target, destination, follow_symlinks=False)


def install(source=None, *, home=None, applications=None):
    translate = Translator()
    source = Path(source or Path(__file__).resolve().parent).resolve()
    home = Path(home or Path.home())
    binary = home / ".local/bin/uniconnect"
    applications = Path(applications or (Path(os.environ.get("XDG_DATA_HOME", str(home / ".local/share")))
                                         / "applications"))
    desktop = applications / "com.unixcision.uniconnect.desktop"
    backup = home / ".local/state/uniconnect/install-backups" / str(time.time_ns())
    for target in (binary, desktop):
        if target.exists() or target.is_symlink():
            backup_target(target, backup)
    binary.parent.mkdir(parents=True, exist_ok=True)
    applications.mkdir(parents=True, exist_ok=True)
    launcher = source / "uniconnect-linux"
    launcher.chmod(launcher.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    if binary.exists() or binary.is_symlink():
        binary.unlink()
    binary.symlink_to(launcher)
    cli = source / "cmux"
    cli.chmod(cli.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    for cli_name in ("uniconnect-cli", "cmux"):
        target = binary.parent / cli_name
        if not target.exists() and not target.is_symlink():
            target.symlink_to(cli)
        elif is_uniconnect_cli(target, cli) and target.resolve() != cli.resolve():
            backup_target(target, backup)
            temporary = target.with_name(f".{target.name}.new.{time.time_ns()}")
            try:
                temporary.symlink_to(cli)
                os.replace(temporary, target)
            finally:
                temporary.unlink(missing_ok=True)
    icon = source.parent / "docs/assets/logo-256.png"
    desktop.write_text("\n".join([
        "[Desktop Entry]", "Type=Application", "Name=UniConnect",
        "Comment=" + translate("Durable local and SSH workspaces"), f'Exec="{launcher}"', f"Icon={icon}",
        "Terminal=false", "Categories=System;TerminalEmulator;Development;",
        "StartupWMClass=UniConnect", "StartupNotify=true", "",
    ]))
    print(binary)
    print(desktop)


def main():
    install()


if __name__ == "__main__":
    main()
