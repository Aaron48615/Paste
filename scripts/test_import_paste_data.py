import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
import uuid

spec = importlib.util.spec_from_file_location(
    "migration", Path(__file__).with_name("import-paste-data.py"))
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.source = Path(self.temp.name) / "original"
        self.destination = Path(self.temp.name) / "independent"
        (self.source / "images").mkdir(parents=True)
        self.image = self.source / "images" / "image.png"
        self.image.write_bytes(b"image fixture")
        self.database = sqlite3.connect(self.source / "clipboard.sqlite3")
        self.addCleanup(self.database.close)
        self.database.execute("PRAGMA journal_mode=WAL")
        self.database.execute("CREATE TABLE items(id TEXT, image_path TEXT, text TEXT)")
        self.database.execute("INSERT INTO items VALUES (?, ?, ?)",
                              ("image", str(self.image), None))
        self.database.commit()

    def test_copies_live_wal_and_rewrites_only_destination_paths(self):
        self.database.execute("INSERT INTO items VALUES ('text', NULL, 'recent')")
        self.database.commit()
        self.assertEqual(migration.copy_history(self.source, self.destination), 2)
        with sqlite3.connect(self.destination / "clipboard.sqlite3") as copied:
            new_path = copied.execute("SELECT image_path FROM items WHERE id='image'").fetchone()[0]
            self.assertEqual(new_path, str(self.destination / "images" / "image.png"))
            self.assertEqual(Path(new_path).read_bytes(), b"image fixture")
            self.assertEqual(copied.execute("SELECT text FROM items WHERE id='text'").fetchone()[0], "recent")
        old_path = self.database.execute("SELECT image_path FROM items WHERE id='image'").fetchone()[0]
        self.assertEqual(old_path, str(self.image))
        self.assertEqual(self.image.read_bytes(), b"image fixture")
        self.assertFalse((self.destination / "controller.sock").exists())

    def test_copies_pinned_card_payloads(self):
        identifier = str(uuid.uuid4()).upper()
        folder = self.source / "pinned-cards"
        (folder / "payloads").mkdir(parents=True)
        manifest = {"version": 1, "cards": [{"id": identifier, "kind": "plain"}]}
        (folder / "session.json").write_text(json.dumps(manifest))
        (folder / "payloads" / (identifier + ".txt")).write_text("pinned fixture")
        migration.copy_history(self.source, self.destination)
        self.assertEqual((self.destination / "pinned-cards" / "payloads" /
                          (identifier + ".txt")).read_text(), "pinned fixture")

    def test_existing_profile_is_never_overwritten(self):
        self.destination.mkdir()
        marker = self.destination / "keep.txt"
        marker.write_text("keep")
        with self.assertRaises(FileExistsError):
            migration.copy_history(self.source, self.destination)
        self.assertEqual(marker.read_text(), "keep")

    def test_missing_image_aborts_before_publishing_profile(self):
        self.image.unlink()
        with self.assertRaises(FileNotFoundError):
            migration.copy_history(self.source, self.destination)
        self.assertFalse(self.destination.exists())


if __name__ == "__main__":
    unittest.main()
