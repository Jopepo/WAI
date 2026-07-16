import importlib.util
import plistlib
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPTS_DIR = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "wai3_upgrade_gate",
    SCRIPTS_DIR / "wai3_upgrade_gate.py",
)
assert SPEC is not None
wai3_upgrade_gate = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.path.insert(0, str(SCRIPTS_DIR))
SPEC.loader.exec_module(wai3_upgrade_gate)


class WAI3UpgradeGateTests(unittest.TestCase):
    bundle_identifier = "com.jplabs.WAI"

    def make_fixture_app(self, root: Path) -> Path:
        app = root / "WAI.app"
        app.mkdir()
        with (app / "Info.plist").open("wb") as handle:
            plistlib.dump({"CFBundleExecutable": "WAI"}, handle)
        (app / "WAI").write_bytes(
            b"\n".join(wai3_upgrade_gate.WAI2_FIXTURE_BINARY_MARKERS)
        )
        return app

    def make_container(self, root: Path) -> Path:
        preferences = root / "Library" / "Preferences"
        caches = root / "Library" / "Caches"
        preferences.mkdir(parents=True)
        caches.mkdir(parents=True)
        with (
            preferences / f"{self.bundle_identifier}.plist"
        ).open("wb") as handle:
            plistlib.dump(
                {
                    "wai.calculationHistory": b"history",
                    "wai.lastCalculation": b"last",
                    "wai.hotelStays": b"stays",
                    wai3_upgrade_gate.SEED_KEY: True,
                    wai3_upgrade_gate.SENTINEL_KEY: "preserve",
                    wai3_upgrade_gate.PRESERVED_REFERENCE_KEY: "utc",
                },
                handle,
            )
        for file_name in wai3_upgrade_gate.LEGACY_CACHE_FILES:
            (caches / file_name).write_bytes(b"legacy-json")
        (caches / wai3_upgrade_gate.UNRELATED_CACHE_FILE).write_bytes(
            b"preserve"
        )
        return root

    def test_accepts_complete_legacy_fixture(self):
        with tempfile.TemporaryDirectory() as directory:
            container = self.make_container(Path(directory))

            errors = wai3_upgrade_gate.legacy_fixture_errors(
                container,
                self.bundle_identifier,
            )

            self.assertEqual(errors, [])

    def test_accepts_only_expected_cleanup_after_upgrade(self):
        with tempfile.TemporaryDirectory() as directory:
            container = self.make_container(Path(directory))
            preferences_path = wai3_upgrade_gate.preferences_path(
                container,
                self.bundle_identifier,
            )
            with preferences_path.open("rb") as handle:
                preferences = plistlib.load(handle)
            for key in wai3_upgrade_gate.LEGACY_SENSITIVE_KEYS:
                del preferences[key]
            with preferences_path.open("wb") as handle:
                plistlib.dump(preferences, handle)
            for file_name in wai3_upgrade_gate.LEGACY_CACHE_FILES:
                (container / "Library" / "Caches" / file_name).unlink()

            errors = wai3_upgrade_gate.upgraded_state_errors(
                container,
                self.bundle_identifier,
            )

            self.assertEqual(errors, [])

    def test_rejects_sensitive_data_that_survives_upgrade(self):
        with tempfile.TemporaryDirectory() as directory:
            container = self.make_container(Path(directory))

            errors = wai3_upgrade_gate.upgraded_state_errors(
                container,
                self.bundle_identifier,
            )

            self.assertTrue(
                any("Legacy personal data survived" in item for item in errors)
            )
            self.assertTrue(
                any("Legacy operational cache survived" in item for item in errors)
            )

    def test_reads_calendar_authorization_from_tcc_schema(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            database = root / "Library" / "TCC" / "TCC.db"
            database.parent.mkdir(parents=True)
            connection = sqlite3.connect(database)
            try:
                connection.execute(
                    "create table access ("
                    "service text, client text, auth_value integer)"
                )
                connection.execute(
                    "insert into access values (?, ?, ?)",
                    (
                        "kTCCServiceCalendarFullAccess",
                        self.bundle_identifier,
                        2,
                    ),
                )
                connection.commit()
            finally:
                connection.close()

            original = wai3_upgrade_gate.simulator_data_path
            try:
                wai3_upgrade_gate.simulator_data_path = lambda _: root
                rows = wai3_upgrade_gate.calendar_permission_rows(
                    "SIMULATOR",
                    self.bundle_identifier,
                )
            finally:
                wai3_upgrade_gate.simulator_data_path = original

            self.assertEqual(
                rows,
                [("kTCCServiceCalendarFullAccess", 2)],
            )

    def test_accepts_release_upgrade_fixture_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_fixture_app(Path(directory))

            wai3_upgrade_gate.validate_wai2_fixture_bundle(app)

    def test_rejects_debug_or_incomplete_upgrade_fixture_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_fixture_app(Path(directory))
            (app / "WAI.debug.dylib").write_bytes(b"debug")

            with self.assertRaises(wai3_upgrade_gate.WAI3UpgradeGateError):
                wai3_upgrade_gate.validate_wai2_fixture_bundle(app)

            (app / "WAI.debug.dylib").unlink()
            (app / "WAI").write_bytes(b"missing markers")
            with self.assertRaises(wai3_upgrade_gate.WAI3UpgradeGateError):
                wai3_upgrade_gate.validate_wai2_fixture_bundle(app)


if __name__ == "__main__":
    unittest.main()
