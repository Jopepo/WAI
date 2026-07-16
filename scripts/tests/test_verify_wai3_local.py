import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import verify_wai3_local  # noqa: E402


class WAI3LocalVerificationTests(unittest.TestCase):
    def configuration(self):
        return (
            verify_wai3_local.build_wai3.WAI3PublicBuildConfiguration
            .from_environment({
                "WAI3_BUNDLE_IDENTIFIER": "com.jplabs.WAI",
                "WAI3_SUPABASE_URL":
                    "https://abcdefghijklmnopqrst.supabase.co",
                "WAI3_SUPABASE_PUBLISHABLE_KEY":
                    "sb_publishable_12345678901234567890",
                "WAI3_APPROVAL_EMAIL": "approval@example.com",
                "WAI3_PRIVACY_POLICY_URL":
                    "https://www.example.com/wai/privacy",
            })
        )

    def test_normal_and_secure_test_boundaries_stay_separate(self):
        paths = verify_wai3_local.WAI3LocalVerificationPaths(
            Path("/tmp/verification")
        )
        normal = verify_wai3_local.make_normal_test_command(
            Path("/project"),
            paths,
            "platform=iOS Simulator,id=SIMULATOR",
        )
        secure = verify_wai3_local.make_secure_ui_test_command(
            Path("/project"),
            paths,
            "platform=iOS Simulator,id=SIMULATOR",
            self.configuration(),
        )

        normal_text = "\n".join(normal)
        secure_text = "\n".join(secure)
        self.assertEqual(normal[:2], ["xcodebuild", "test"])
        self.assertNotIn("WAI_APP_INFO_PLIST", normal_text)
        self.assertNotIn("WAI_APP_EXCLUDED_SOURCE_FILE_NAMES", normal_text)
        self.assertIn("WAI_APP_INFO_PLIST=WAI/WAI3-Info.plist", secure)
        self.assertIn("PRODUCT_BUNDLE_IDENTIFIER=com.jplabs.WAI", secure)
        self.assertIn("WAI_APP_EXCLUDED_SOURCE_FILE_NAMES", secure_text)
        self.assertIn(
            "-only-testing:WAIUITests/WAIUITests/"
            "testSecureEntryPointExposesPrivacyPolicy",
            secure,
        )
        self.assertIn(
            "-only-testing:WAIUITests/WAIUITests/"
            "testApprovedFixtureCoversCrewWorkspace",
            secure,
        )
        self.assertIn(
            "-only-testing:WAIUITests/WAIUITests/"
            "testApprovedFixtureSupportsDarkAccessibilityContent",
            secure,
        )

    def test_artifacts_are_new_and_simulator_id_is_strict(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifacts = root / "artifacts"

            resolved = verify_wai3_local.prepare_artifacts_directory(artifacts)

            self.assertEqual(resolved, artifacts.resolve())
            with self.assertRaises(
                verify_wai3_local.WAI3LocalVerificationError
            ):
                verify_wai3_local.prepare_artifacts_directory(artifacts)

        simulator = "3ebf23d4-c28e-41d3-9708-aaeaa14e9539"
        self.assertEqual(
            verify_wai3_local.validate_simulator_id(simulator),
            simulator.upper(),
        )
        with self.assertRaises(verify_wai3_local.WAI3LocalVerificationError):
            verify_wai3_local.validate_simulator_id("not-a-simulator")

    def test_orchestrator_runs_only_local_build_and_test_gates(self):
        project_root = Path("/project")
        artifacts = Path("/tmp/verification")
        commands = []

        with mock.patch.object(
            verify_wai3_local,
            "run_command",
            side_effect=lambda command, **_: commands.append(command),
        ), mock.patch.object(
            verify_wai3_local.build_wai3,
            "validate_source_info_plist",
        ), mock.patch.object(
            verify_wai3_local.wai2_invariant_gate,
            "validate_app_bundle",
        ), mock.patch.object(
            verify_wai3_local.wai3_upgrade_gate,
            "validate_wai2_fixture_bundle",
        ), mock.patch.object(
            verify_wai3_local.wai3_release_gate,
            "validate_app_bundle",
        ), mock.patch.object(
            verify_wai3_local.wai3_upgrade_gate,
            "run_upgrade_gate",
        ) as upgrade:
            paths = verify_wai3_local.run_verification(
                project_root=project_root,
                artifacts_root=artifacts,
                simulator_id="3EBF23D4-C28E-41D3-9708-AAEAA14E9539",
                configuration=self.configuration(),
            )

        self.assertEqual(paths.root, artifacts)
        self.assertEqual(len(commands), 6)
        xcode_actions = [
            command[1]
            for command in commands
            if command[0] == "xcodebuild"
        ]
        self.assertEqual(xcode_actions, ["test", "test", "build", "build", "build"])
        command_text = "\n".join(item for command in commands for item in command)
        self.assertNotIn("archive", command_text.lower())
        self.assertNotIn("upload", command_text.lower())
        self.assertNotIn("testflight", command_text.lower())
        self.assertIn("CODE_SIGNING_ALLOWED=NO", commands[-1])
        upgrade.assert_called_once()
        self.assertEqual(
            upgrade.call_args.kwargs["simulator_id"],
            "3EBF23D4-C28E-41D3-9708-AAEAA14E9539",
        )


if __name__ == "__main__":
    unittest.main()
