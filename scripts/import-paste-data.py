#!/usr/bin/env python3
"""Copy Paste data into a new RePaste profile without modifying the source."""

from __future__ import annotations

import json
import os
from pathlib import Path
import plistlib
import shutil
import sqlite3
import subprocess
import tempfile
import uuid

SOURCE_ID = "com.eli.Paste"
DESTINATION_ID = "com.aaron.RePaste"


def copy_history(source: Path, destination: Path) -> int:
    """Publish a validated snapshot atomically; never replace an existing profile."""
    if destination.exists():
        raise FileExistsError("RePaste data already exists; refusing to overwrite it")
    database = source / "clipboard.sqlite3"
    if not database.is_file():
        raise FileNotFoundError("No Paste clipboard database found")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".repaste-import-", dir=destination.parent) as temp:
        staging = Path(temp) / "profile"
        staging.mkdir(mode=0o700)
        images = staging / "images"
        images.mkdir(mode=0o700)
        with sqlite3.connect(database.as_uri() + "?mode=ro", uri=True) as original:
            with sqlite3.connect(staging / "clipboard.sqlite3") as copied:
                # Includes committed WAL changes without copying a live WAL file.
                original.backup(copied)
                copied.execute("PRAGMA journal_mode=DELETE")
                rows = copied.execute(
                    "SELECT id, image_path FROM items WHERE image_path IS NOT NULL"
                ).fetchall()
                for item_id, old_path in rows:
                    old = Path(old_path)
                    if (old.parent.resolve() != (source / "images").resolve()
                            or old.is_symlink() or old.suffix.lower() != ".png"):
                        raise ValueError("Image path is outside Paste's managed images directory")
                    shutil.copy2(old, images / old.name)
                    copied.execute("UPDATE items SET image_path = ? WHERE id = ?",
                                   (str(destination / "images" / old.name), item_id))
                copied.commit()
                if copied.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                    raise ValueError("Copied clipboard database failed integrity check")
                count = copied.execute("SELECT COUNT(*) FROM items").fetchone()[0]

        manifest = source / "pinned-cards" / "session.json"
        if manifest.exists():
            # Copy a single manifest snapshot and exactly the payloads it references.
            contents = manifest.read_bytes()
            records = json.loads(contents)
            target = staging / "pinned-cards"
            payloads = target / "payloads"
            payloads.mkdir(parents=True, mode=0o700)
            for card in records.get("cards", []):
                identifier = str(uuid.UUID(card["id"])).upper()
                extension = "png" if card["kind"] == "image" else "txt"
                filename = identifier + "." + extension
                shutil.copy2(source / "pinned-cards" / "payloads" / filename, payloads / filename)
            (target / "session.json").write_bytes(contents)

        # Do not transfer controller.sock, WAL/SHM files, or running-app state.
        for root, directories, files in os.walk(staging):
            os.chmod(root, 0o700)
            for name in files:
                os.chmod(Path(root) / name, 0o600)
        if destination.exists():
            raise FileExistsError("RePaste started during import; refusing to overwrite it")
        staging.rename(destination)
    return count


def export_preferences(domain: str) -> dict | None:
    result = subprocess.run(["defaults", "export", domain, "-"], capture_output=True)
    if result.returncode != 0:
        return None
    return plistlib.loads(result.stdout)


def main() -> None:
    support = Path.home() / "Library" / "Application Support"
    destination = support / DESTINATION_ID
    if destination.exists() or export_preferences(DESTINATION_ID):
        raise FileExistsError("RePaste already has data or settings; refusing to overwrite them")
    settings = export_preferences(SOURCE_ID)
    if settings is None:
        raise RuntimeError("Unable to read Paste settings; no migration performed")
    # Sparkle preferences belong to the old update channel, not this fork.
    settings = {key: value for key, value in settings.items() if not key.startswith("SU")}
    count = copy_history(support / SOURCE_ID, destination)
    try:
        with tempfile.TemporaryDirectory(prefix="repaste-settings-") as temp:
            preferences = Path(temp) / "settings.plist"
            preferences.write_bytes(plistlib.dumps(settings))
            os.chmod(preferences, 0o600)
            result = subprocess.run(
                ["defaults", "import", DESTINATION_ID, str(preferences)], capture_output=True)
            if result.returncode != 0:
                raise RuntimeError("Settings import failed; copied history is preserved")
        if export_preferences(DESTINATION_ID) != settings:
            raise RuntimeError("Settings verification failed; copied history is preserved")
    except Exception:
        print("History was copied. Do not rerun over this profile; inspect the settings failure.")
        raise
    print(f"Copied {count} clipboard records and {len(settings)} settings into RePaste.")
    print("Original Paste data and permissions were left unchanged.")


if __name__ == "__main__":
    main()
