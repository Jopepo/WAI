import importlib.util
import os
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
MODULE_PATH = SCRIPTS / "build_wai3.py"
SPEC = importlib.util.spec_from_file_location("build_wai3", MODULE_PATH)
build_wai3 = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = build_wai3
SPEC.loader.exec_module(build_wai3)


class WAI3BuildTests(unittest.TestCase):
    def valid_environment(self):
        return {
            "WAI3_SUPABASE_URL":
                "https://abcdefghijklmnopqrst.supabase.co",
            "WAI3_SUPABASE_PUBLISHABLE_KEY":
                "sb_publishable_12345678901234567890",
            "WAI3_APPROVAL_EMAIL": "approval@example.com",
            "WAI3_PRIVACY_POLICY_URL":
                "https://www.example.com/wai/privacy",
        }

    def test_requires_only_public_runtime_configuration(self):
        configuration = build_wai3.WAI3PublicBuildConfiguration.from_environment(
            self.valid_environment()
        )

        settings = configuration.xcode_build_settings()

        self.assertIn("WAI_APP_INFO_PLIST=WAI/WAI3-Info.plist", settings)
        self.assertTrue(
            any(item == "WAI_APP_MARKETING_VERSION=3.0" for item in settings)
        )
        self.assertTrue(
            any(item == "WAI_APP_BUILD_NUMBER=17" for item in settings)
        )
        joined = "\n".join(settings)
        self.assertNotIn("service_role", joined.lower())
        self.assertNotIn("private key", joined.lower())
        for file_name in build_wai3.OPERATIONAL_JSON_FILES:
            self.assertIn(file_name, joined)

    def test_rejects_missing_or_unsafe_configuration(self):
        with self.assertRaises(build_wai3.WAI3BuildConfigurationError):
            build_wai3.WAI3PublicBuildConfiguration.from_environment({})

        invalid = self.valid_environment()
        invalid["WAI3_PRIVACY_POLICY_URL"] = "https://127.0.0.1/privacy"
        with self.assertRaises(build_wai3.WAI3BuildConfigurationError):
            build_wai3.WAI3PublicBuildConfiguration.from_environment(invalid)

    def test_build_command_has_no_upload_or_install_action(self):
        configuration = build_wai3.WAI3PublicBuildConfiguration.from_environment(
            self.valid_environment()
        )
        command = build_wai3.make_build_command(
            Path("/project"),
            Path("/tmp/derived"),
            "generic/platform=iOS Simulator",
            configuration,
        )

        self.assertEqual(command[:2], ["xcodebuild", "build"])
        self.assertNotIn("archive", command)
        self.assertNotIn("install", command)
        self.assertNotIn("upload", command)

    def test_device_build_is_unsigned_and_uses_device_product(self):
        configuration = build_wai3.WAI3PublicBuildConfiguration.from_environment(
            self.valid_environment()
        )
        command = build_wai3.make_build_command(
            Path("/project"),
            Path("/tmp/derived"),
            "generic/platform=iOS",
            configuration,
            device_build=True,
        )

        self.assertIn("CODE_SIGNING_ALLOWED=NO", command)
        self.assertEqual(
            build_wai3.built_app_path(
                Path("/tmp/derived"),
                device_build=True,
            ),
            Path("/tmp/derived/Build/Products/Release-iphoneos/WAI.app"),
        )

    def test_source_info_is_secure_and_has_no_legacy_url_keys(self):
        project_root = Path(__file__).resolve().parents[2]

        build_wai3.validate_source_info_plist(project_root)

        with (project_root / "WAI/WAI3-Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
        self.assertIs(info["WAI3SecureModeEnabled"], True)
        self.assertFalse(
            build_wai3.wai3_release_gate.LEGACY_URL_KEYS.intersection(info)
        )

    def test_main_builds_then_validates_without_deploying(self):
        with tempfile.TemporaryDirectory() as directory:
            derived_data = Path(directory) / "DerivedData"
            app = build_wai3.built_app_path(derived_data)
            app.mkdir(parents=True)
            with mock.patch.dict(os.environ, self.valid_environment(), clear=True), \
                 mock.patch.object(build_wai3.subprocess, "run") as run, \
                 mock.patch.object(
                     build_wai3.wai3_release_gate,
                     "validate_app_bundle",
                 ) as validate:
                result = build_wai3.main([
                    "--derived-data",
                    str(derived_data),
                ])

            self.assertEqual(result, 0)
            run.assert_called_once()
            self.assertIs(run.call_args.kwargs["check"], True)
            validate.assert_called_once_with(app.resolve())


if __name__ == "__main__":
    unittest.main()
