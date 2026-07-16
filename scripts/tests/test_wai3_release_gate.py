import importlib.util
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "wai3_release_gate.py"
SPEC = importlib.util.spec_from_file_location("wai3_release_gate", MODULE_PATH)
wai3_release_gate = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = wai3_release_gate
SPEC.loader.exec_module(wai3_release_gate)


class WAI3ReleaseGateTests(unittest.TestCase):
    def make_app(self, root: Path) -> Path:
        app = root / "WAI.app"
        app.mkdir()
        info = {
            "CFBundleIdentifier": "com.jplabs.WAI",
            "CFBundleShortVersionString": "3.0",
            "CFBundleVersion": "17",
            "WAI3SecureModeEnabled": True,
            "WAI3CompatibilityVersion": "3.0",
            "WAISupabaseURL": "https://abcdefghijklmnopqrst.supabase.co",
            "WAISupabasePublishableKey": "sb_publishable_12345678901234567890",
            "WAIApprovalEmail": "approval@example.com",
            "WAIPrivacyPolicyURL": "https://www.example.com/wai/privacy",
        }
        with (app / "Info.plist").open("wb") as handle:
            plistlib.dump(info, handle)
        privacy = {
            "NSPrivacyTracking": False,
            "NSPrivacyTrackingDomains": [],
            "NSPrivacyAccessedAPITypes": [
                {
                    "NSPrivacyAccessedAPIType":
                        "NSPrivacyAccessedAPICategoryUserDefaults",
                    "NSPrivacyAccessedAPITypeReasons": ["CA92.1"],
                },
                {
                    "NSPrivacyAccessedAPIType":
                        "NSPrivacyAccessedAPICategoryFileTimestamp",
                    "NSPrivacyAccessedAPITypeReasons": ["C617.1"],
                },
            ],
            "NSPrivacyCollectedDataTypes": [
                {
                    "NSPrivacyCollectedDataType": data_type,
                    "NSPrivacyCollectedDataTypeLinked": True,
                    "NSPrivacyCollectedDataTypeTracking": False,
                    "NSPrivacyCollectedDataTypePurposes": [
                        "NSPrivacyCollectedDataTypePurposeAppFunctionality"
                    ],
                }
                for data_type in (
                    "NSPrivacyCollectedDataTypeName",
                    "NSPrivacyCollectedDataTypeEmailAddress",
                    "NSPrivacyCollectedDataTypeUserID",
                )
            ],
        }
        with (app / "PrivacyInfo.xcprivacy").open("wb") as handle:
            plistlib.dump(privacy, handle)
        (app / "WAI").write_bytes(b"compiled executable")
        return app

    def test_accepts_private_secure_build(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(Path(directory))

            wai3_release_gate.validate_app_bundle(app)

    def test_enforces_expected_bundle_identifier(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(Path(directory))

            wai3_release_gate.validate_app_bundle(
                app,
                expected_bundle_identifier="com.jplabs.WAI",
            )
            errors = wai3_release_gate.release_gate_errors(
                app,
                expected_bundle_identifier="com.jplabs.WAI.staging",
            )

            self.assertIn(
                "CFBundleIdentifier does not match the expected build identifier",
                errors,
            )

    def test_rejects_invalid_bundle_identifier(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(Path(directory))
            info_path = app / "Info.plist"
            with info_path.open("rb") as handle:
                info = plistlib.load(handle)
            info["CFBundleIdentifier"] = "com.jplabs.WAI.*"
            with info_path.open("wb") as handle:
                plistlib.dump(info, handle)

            errors = wai3_release_gate.release_gate_errors(app)

            self.assertIn("CFBundleIdentifier is missing or invalid", errors)

    def test_rejects_legacy_urls_and_operational_json(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(Path(directory))
            info_path = app / "Info.plist"
            with info_path.open("rb") as handle:
                info = plistlib.load(handle)
            info["WAITransportRulesURL"] = (
                "https://raw.githubusercontent.com/Jopepo/WAI/main/data.json"
            )
            with info_path.open("wb") as handle:
                plistlib.dump(info, handle)
            (app / "wai_transport_rules_current.json").write_text(
                "{}", encoding="utf-8"
            )

            errors = wai3_release_gate.release_gate_errors(app)

            self.assertTrue(any("Legacy public data URL" in item for item in errors))
            self.assertTrue(any("Operational JSON" in item for item in errors))

    def test_rejects_secret_markers_in_any_bundle_file(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(Path(directory))
            (app / "WAI").write_bytes(b"prefix sb_secret_do_not_ship suffix")

            errors = wai3_release_gate.release_gate_errors(app)

            self.assertTrue(any("sb_secret_" in item for item in errors))

    def test_rejects_debug_fixture_markers_in_release_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(Path(directory))
            (app / "WAI").write_bytes(
                b"prefix wai3-approved-ui-test-fixture suffix"
            )

            errors = wai3_release_gate.release_gate_errors(app)

            self.assertTrue(
                any("wai3-approved-ui-test-fixture" in item for item in errors)
            )

    def test_rejects_upgrade_fixture_markers_in_release_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(Path(directory))
            (app / "WAI").write_bytes(
                b"prefix wai2-upgrade-test-fixture suffix"
            )

            errors = wai3_release_gate.release_gate_errors(app)

            self.assertTrue(
                any("wai2-upgrade-test-fixture" in item for item in errors)
            )

    def test_rejects_upgrade_fixture_failure_marker_in_release_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(Path(directory))
            (app / "WAI").write_bytes(
                b"prefix wai.debug.upgradeFixtureFailure suffix"
            )

            errors = wai3_release_gate.release_gate_errors(app)

            self.assertTrue(
                any(
                    "wai.debug.upgradeFixtureFailure" in item
                    for item in errors
                )
            )

    def test_rejects_upgrade_fixture_environment_in_release_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(Path(directory))
            (app / "WAI").write_bytes(
                b"prefix WAI2_UPGRADE_TEST_FIXTURE suffix"
            )

            errors = wai3_release_gate.release_gate_errors(app)

            self.assertTrue(
                any("WAI2_UPGRADE_TEST_FIXTURE" in item for item in errors)
            )

    def test_rejects_build_with_secure_mode_disabled(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(Path(directory))
            info_path = app / "Info.plist"
            with info_path.open("rb") as handle:
                info = plistlib.load(handle)
            info["WAI3SecureModeEnabled"] = False
            with info_path.open("wb") as handle:
                plistlib.dump(info, handle)

            errors = wai3_release_gate.release_gate_errors(app)

            self.assertIn("WAI3SecureModeEnabled must be true", errors)

    def test_rejects_missing_privacy_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(Path(directory))
            (app / "PrivacyInfo.xcprivacy").unlink()

            errors = wai3_release_gate.release_gate_errors(app)

            self.assertIn("PrivacyInfo.xcprivacy is missing or invalid", errors)

    def test_rejects_missing_or_unsafe_privacy_policy_url(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(Path(directory))
            info_path = app / "Info.plist"
            with info_path.open("rb") as handle:
                info = plistlib.load(handle)
            del info["WAIPrivacyPolicyURL"]
            with info_path.open("wb") as handle:
                plistlib.dump(info, handle)

            errors = wai3_release_gate.release_gate_errors(app)

            self.assertIn(
                "WAIPrivacyPolicyURL must be a safe public HTTPS URL",
                errors,
            )

            for unsafe_url in (
                "https://example.com/privacy?token=secret",
                "https://127.0.0.1/privacy",
                "https://privacy.internal/policy",
            ):
                info["WAIPrivacyPolicyURL"] = unsafe_url
                with info_path.open("wb") as handle:
                    plistlib.dump(info, handle)

                errors = wai3_release_gate.release_gate_errors(app)

                self.assertIn(
                    "WAIPrivacyPolicyURL must be a safe public HTTPS URL",
                    errors,
                )


if __name__ == "__main__":
    unittest.main()
