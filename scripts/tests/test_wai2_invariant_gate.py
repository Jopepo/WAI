import importlib.util
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "wai2_invariant_gate.py"
SPEC = importlib.util.spec_from_file_location("wai2_invariant_gate", MODULE_PATH)
wai2_invariant_gate = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = wai2_invariant_gate
SPEC.loader.exec_module(wai2_invariant_gate)


class WAI2InvariantGateTests(unittest.TestCase):
    def make_app(self, root: Path) -> Path:
        app = root / "WAI.app"
        app.mkdir()
        info = {
            "CFBundleShortVersionString": "2.2",
            "CFBundleVersion": "16",
            **wai2_invariant_gate.EXPECTED_URLS,
        }
        with (app / "Info.plist").open("wb") as handle:
            plistlib.dump(info, handle)
        for file_name in wai2_invariant_gate.EXPECTED_JSON_FILES:
            (app / file_name).write_text("{}", encoding="utf-8")
        return app

    def test_accepts_unchanged_wai_2_2_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(Path(directory))

            wai2_invariant_gate.validate_app_bundle(app)

    def test_rejects_version_or_secure_mode_change(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(Path(directory))
            info_path = app / "Info.plist"
            with info_path.open("rb") as handle:
                info = plistlib.load(handle)
            info["CFBundleShortVersionString"] = "3.0"
            info["WAI3SecureModeEnabled"] = True
            with info_path.open("wb") as handle:
                plistlib.dump(info, handle)

            errors = wai2_invariant_gate.invariant_errors(app)

            self.assertIn("Legacy build must remain version 2.2", errors)
            self.assertIn(
                "Legacy build must not enable WAI 3 secure mode",
                errors,
            )

    def test_rejects_changed_url_or_missing_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(Path(directory))
            info_path = app / "Info.plist"
            with info_path.open("rb") as handle:
                info = plistlib.load(handle)
            info["WAIRemoteWhatsNewURL"] = "https://example.com/changed.json"
            with info_path.open("wb") as handle:
                plistlib.dump(info, handle)
            missing = next(iter(wai2_invariant_gate.EXPECTED_JSON_FILES))
            (app / missing).unlink()

            errors = wai2_invariant_gate.invariant_errors(app)

            self.assertIn(
                "Legacy remote URL changed: WAIRemoteWhatsNewURL",
                errors,
            )
            self.assertTrue(
                any("Legacy bundled fallback is missing" in item for item in errors)
            )


if __name__ == "__main__":
    unittest.main()
