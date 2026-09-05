"""Install launchers referencing this source checkout; preserve existing launchers."""

import os
from pathlib import Path
import shutil
import stat
import time


def main():
    source = Path(__file__).resolve().parent
    binary = Path.home() / ".local/bin/uniconnect"
    applications = Path(os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share"))) / "applications"
    desktop = applications / "com.unixcision.uniconnect.desktop"
    backup = Path.home() / ".local/state/uniconnect/install-backups" / str(time.time_ns())
    for target in (binary, desktop):
        if target.exists() or target.is_symlink():
            backup.mkdir(parents=True, mode=0o700, exist_ok=True)
            shutil.copy2(target, backup / target.name, follow_symlinks=False)
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
    icon = source.parent / "docs/assets/logo-256.png"
    desktop.write_text("\n".join([
        "[Desktop Entry]", "Type=Application", "Name=UniConnect",
        "Comment=Persistent local and SSH workspaces", "Comment[es]=Cajas locales y SSH persistentes",
        "Comment[ja]=永続的なローカルと SSH ワークスペース", f'Exec="{launcher}"', f"Icon={icon}",
        "Terminal=false", "Categories=System;TerminalEmulator;Development;",
        "StartupWMClass=UniConnect", "StartupNotify=true", "",
    ]))
    print(binary)
    print(desktop)


if __name__ == "__main__":
    main()
