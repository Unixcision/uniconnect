#!/usr/bin/env python3
"""Generate a private, read-only migration plan for Desktop phase 2.

The script inventories filesystem metadata without following symlinks. It never
moves, renames, edits, or deletes a source item. Generated reports contain paths
and metadata, but never file contents.
"""

from __future__ import annotations

import argparse
import datetime as dt
import gzip
import hashlib
import json
import os
import shlex
import stat
import sys
from pathlib import Path
from typing import Any, Iterator


USER_ROOT = Path("/Users/danielgomezmartin")
DESKTOP_ROOT = USER_ROOT / "Desktop"
DEVELOPMENT_ROOT = DESKTOP_ROOT / "DESARROLLO"

MOVE_CANDIDATES = (
    "2DS.DEV",
    "3XA",
    "NOTBETTING",
    "PROYECTOS",
    "PYTHON SCRIPTS",
    "RASPBER",
)

KEEP_IN_PLACE = (
    "PassCodeApp.vault",
)

OPTIONAL_MOVES = (
    {
        "source": USER_ROOT / "AndroidStudioProjects" / "PongFrenetico",
        "destination": DESKTOP_ROOT / "PROYECTOS" / "MOBILE_APPS" / "PongFrenetico",
        "reason": "Requires separate approval before joining the mobile-app group.",
    },
)

DEPENDENCY_FILES = (
    USER_ROOT / ".claude.json",
    USER_ROOT / ".ssh" / "config",
    USER_ROOT / "Downloads" / "CONNECT.md",
    DESKTOP_ROOT / "CLAUDE.md",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output",
        type=Path,
        required=True,
        help="New private directory that will receive the generated plan.",
    )
    return parser.parse_args()


def require_safe_output(path: Path) -> Path:
    resolved = path.expanduser().resolve(strict=False)
    allowed_root = USER_ROOT / ".uniconnect" / "backups"
    if resolved == allowed_root or allowed_root not in resolved.parents:
        raise ValueError(f"output must be a child of {allowed_root}")
    if resolved.exists():
        raise FileExistsError(f"output already exists: {resolved}")
    resolved.mkdir(mode=0o700, parents=True)
    os.chmod(resolved, 0o700)
    return resolved


def atomic_write(path: Path, data: bytes, mode: int = 0o600) -> None:
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        os.chmod(path, mode)
    except BaseException:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
        raise


def path_record(root: Path, path: Path) -> dict[str, Any]:
    metadata = path.lstat()
    kind = "other"
    link_target: str | None = None
    if stat.S_ISDIR(metadata.st_mode):
        kind = "directory"
    elif stat.S_ISREG(metadata.st_mode):
        kind = "file"
    elif stat.S_ISLNK(metadata.st_mode):
        kind = "symlink"
        link_target = os.readlink(path)

    relative = "." if path == root else str(path.relative_to(root))
    return {
        "relativePath": relative,
        "kind": kind,
        "size": metadata.st_size,
        "allocatedBytes": metadata.st_blocks * 512,
        "mtimeNanoseconds": metadata.st_mtime_ns,
        "mode": stat.S_IMODE(metadata.st_mode),
        "device": metadata.st_dev,
        "inode": metadata.st_ino,
        **({"linkTarget": link_target} if link_target is not None else {}),
    }


def walk_without_following_links(root: Path) -> Iterator[dict[str, Any]]:
    yield path_record(root, root)
    pending = [root]
    while pending:
        directory = pending.pop()
        try:
            entries = sorted(os.scandir(directory), key=lambda item: item.name)
        except (OSError, PermissionError) as error:
            yield {
                "relativePath": str(directory.relative_to(root)),
                "kind": "unreadable-directory",
                "error": error.__class__.__name__,
            }
            continue
        child_directories: list[Path] = []
        for entry in entries:
            child = Path(entry.path)
            try:
                record = path_record(root, child)
            except (OSError, PermissionError) as error:
                yield {
                    "relativePath": str(child.relative_to(root)),
                    "kind": "unreadable-entry",
                    "error": error.__class__.__name__,
                }
                continue
            yield record
            if record["kind"] == "directory":
                child_directories.append(child)
        pending.extend(reversed(child_directories))


def write_inventory(root: Path, destination: Path) -> dict[str, Any]:
    summary: dict[str, Any] = {
        "source": str(root),
        "exists": root.exists(),
        "entries": 0,
        "files": 0,
        "directories": 0,
        "symlinks": 0,
        "unreadable": 0,
        "logicalBytes": 0,
        "allocatedBytes": 0,
    }
    if not root.exists():
        return summary

    digest = hashlib.sha256()
    temporary = destination.with_name(f".{destination.name}.tmp-{os.getpid()}")
    with gzip.open(temporary, "wt", encoding="utf-8", newline="\n") as handle:
        for record in walk_without_following_links(root):
            serialized = json.dumps(record, ensure_ascii=False, sort_keys=True)
            handle.write(serialized + "\n")
            digest.update(serialized.encode("utf-8") + b"\n")
            summary["entries"] += 1
            kind = record["kind"]
            if kind == "file":
                summary["files"] += 1
            elif kind == "directory":
                summary["directories"] += 1
            elif kind == "symlink":
                summary["symlinks"] += 1
            elif kind.startswith("unreadable"):
                summary["unreadable"] += 1
            summary["logicalBytes"] += int(record.get("size", 0))
            summary["allocatedBytes"] += int(record.get("allocatedBytes", 0))
    os.replace(temporary, destination)
    os.chmod(destination, 0o600)
    summary["inventory"] = destination.name
    summary["inventoryContentSHA256"] = digest.hexdigest()
    return summary


def encoded_claude_slug(path: Path) -> str:
    return str(path).replace("/", "-")


def dependency_report(operations: list[dict[str, Any]]) -> dict[str, Any]:
    needles: dict[str, list[str]] = {}
    for operation in operations:
        source = Path(operation["source"])
        needles[str(source)] = [
            str(source),
            encoded_claude_slug(source),
        ]

    references: list[dict[str, Any]] = []
    for candidate in DEPENDENCY_FILES:
        if not candidate.is_file():
            continue
        try:
            with candidate.open("r", encoding="utf-8", errors="replace") as handle:
                for line_number, line in enumerate(handle, start=1):
                    for source, variants in needles.items():
                        if any(variant in line for variant in variants):
                            references.append(
                                {
                                    "file": str(candidate),
                                    "line": line_number,
                                    "referencesSource": source,
                                }
                            )
        except OSError as error:
            references.append(
                {
                    "file": str(candidate),
                    "error": error.__class__.__name__,
                }
            )

    claude_projects = USER_ROOT / ".claude" / "projects"
    project_slugs: list[dict[str, Any]] = []
    if claude_projects.is_dir():
        try:
            names = {entry.name: entry for entry in os.scandir(claude_projects)}
            for operation in operations:
                source = Path(operation["source"])
                destination = Path(operation["destination"])
                source_slug = encoded_claude_slug(source)
                matching = sorted(name for name in names if name.startswith(source_slug))
                if matching:
                    project_slugs.append(
                        {
                            "source": str(source),
                            "destination": str(destination),
                            "currentSlugPrefix": source_slug,
                            "proposedSlugPrefix": encoded_claude_slug(destination),
                            "matchingEntries": matching,
                            "action": "plan-copy-and-verify; never rewrite JSONL in place",
                        }
                    )
        except OSError as error:
            project_slugs.append({"error": error.__class__.__name__})

    return {
        "contentWasIncluded": False,
        "knownFileReferences": references,
        "claudeProjectSlugChanges": project_slugs,
        "requiredFollowUp": [
            "Update path references in CONNECT.md only after the filesystem move succeeds.",
            "Update ~/.claude.json through a separately backed-up, schema-aware migration.",
            "Copy Claude project slug directories first; verify transcripts before retiring old slugs.",
            "Review ~/.ssh/config and CLAUDE.md references without publishing their contents.",
            "Restart no live terminal automatically; reopen each against its persisted new cwd.",
        ],
    }


def rollback_script(operations: list[dict[str, Any]]) -> str:
    lines = [
        "#!/bin/sh",
        "set -eu",
        "",
        'if [ "${UNICONNECT_DESKTOP_PHASE2_ROLLBACK:-}" != "I_UNDERSTAND" ]; then',
        '  echo "Dry-run only. Set UNICONNECT_DESKTOP_PHASE2_ROLLBACK=I_UNDERSTAND to apply." >&2',
        "  exit 2",
        "fi",
        "",
    ]
    for operation in reversed(operations):
        source = shlex.quote(operation["source"])
        destination = shlex.quote(operation["destination"])
        source_parent = shlex.quote(str(Path(operation["source"]).parent))
        lines.extend(
            [
                f"if [ -e {source} ]; then",
                f"  echo 'REFUSE: original path already exists: {source}' >&2",
                "  exit 3",
                "fi",
                f"if [ ! -e {destination} ]; then",
                f"  echo 'REFUSE: moved path is missing: {destination}' >&2",
                "  exit 4",
                "fi",
                f"mkdir -p {source_parent}",
                f"mv {destination} {source}",
                "",
            ]
        )
    return "\n".join(lines)


def proposed_operations() -> list[dict[str, Any]]:
    operations = []
    for name in MOVE_CANDIDATES:
        source = DESKTOP_ROOT / name
        destination = DEVELOPMENT_ROOT / name
        operations.append(
            {
                "source": str(source),
                "destination": str(destination),
                "policy": "requires-separate-user-approval",
                "sourceExists": source.exists(),
                "destinationExists": destination.exists(),
            }
        )
    return operations


def render_readme(
    output: Path,
    operations: list[dict[str, Any]],
    summaries: list[dict[str, Any]],
) -> str:
    lines = [
        "# Desktop phase 2 — private dry-run",
        "",
        "No source path was moved, renamed, edited or deleted by this run.",
        "",
        "## Proposed tree",
        "",
        "```text",
        str(DEVELOPMENT_ROOT),
    ]
    lines.extend(f"├── {Path(operation['destination']).name}" for operation in operations)
    lines.extend(
        [
            "```",
            "",
            "`PassCodeApp.vault` remains at the Desktop root. `IMPUESTOS` has no",
            "approved destination and is intentionally absent from the move manifest.",
            "The optional PongFrenetico move also requires its own approval.",
            "",
            "## Inventory summaries",
            "",
        ]
    )
    for summary in summaries:
        lines.append(
            f"- `{summary['source']}`: {summary['entries']} entries, "
            f"{summary['logicalBytes']} logical bytes, "
            f"{summary['unreadable']} unreadable entries."
        )
    lines.extend(
        [
            "",
            "Exact per-entry metadata is stored in the gzip JSONL inventories. Compare",
            "their recorded SHA-256 values before any approved move and regenerate the",
            "inventory afterwards. The rollback script is guarded and was not run.",
            "",
            f"Plan directory: `{output}`",
            "",
        ]
    )
    return "\n".join(lines)


def main() -> int:
    arguments = parse_args()
    try:
        output = require_safe_output(arguments.output)
    except (ValueError, FileExistsError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    operations = proposed_operations()
    summaries: list[dict[str, Any]] = []
    for index, operation in enumerate(operations, start=1):
        source = Path(operation["source"])
        inventory_name = f"inventory-{index:02d}-{source.name.replace(' ', '-')}.jsonl.gz"
        summaries.append(write_inventory(source, output / inventory_name))

    generated_at = dt.datetime.now(dt.timezone.utc).isoformat()
    plan = {
        "format": "uniconnect-desktop-phase2-plan",
        "version": 1,
        "generatedAt": generated_at,
        "dryRun": True,
        "operations": operations,
        "keepInPlace": [str(DESKTOP_ROOT / name) for name in KEEP_IN_PLACE],
        "requiresDestinationDecision": [str(DESKTOP_ROOT / "IMPUESTOS")],
        "optionalMoves": [
            {key: str(value) if isinstance(value, Path) else value for key, value in move.items()}
            for move in OPTIONAL_MOVES
        ],
        "inventorySummaries": summaries,
        "dependencies": dependency_report(operations),
    }
    manifest_bytes = (json.dumps(plan, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
    atomic_write(output / "manifest.json", manifest_bytes)
    atomic_write(output / "rollback.sh", rollback_script(operations).encode("utf-8"), 0o600)
    atomic_write(output / "README.md", render_readme(output, operations, summaries).encode("utf-8"))
    print(json.dumps({"output": str(output), "dryRun": True, "operations": len(operations)}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
