import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
MODULE_PATH = SCRIPTS / "build_wai2_upgrade_fixture.py"
SPEC = importlib.util.spec_from_file_location(
    "build_wai2_upgrade_fixture",
    MODULE_PATH,
)
build_fixture = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(build_fixture)


class WAI2UpgradeFixtureBuildTests(unittest.TestCase):
    def test_build_command_is_release_only_and_never_deploys(self):
        command = build_fixture.make_build_command(
            Path("/project"),
            Path("/tmp/derived"),
            "generic/platform=iOS Simulator",
        )

        self.assertEqual(command[:2], ["xcodebuild", "build"])
        self.assertIn("Release", command)
        self.assertIn("WAI_UPGRADE_TEST_FIXTURE", "\n".join(command))
        self.assertNotIn("archive", command)
        self.assertNotIn("install", command)
        self.assertNotIn("upload", command)

    def test_main_builds_and_validates_without_deploying(self):
        with tempfile.TemporaryDirectory() as directory:
            derived_data = Path(directory) / "DerivedData"
            app = build_fixture.built_app_path(derived_data)
            app.mkdir(parents=True)
            with mock.patch.object(
                build_fixture.subprocess,
                "run",
            ) as run, mock.patch.object(
                build_fixture.wai2_invariant_gate,
                "validate_app_bundle",
            ) as validate_wai2, mock.patch.object(
                build_fixture.wai3_upgrade_gate,
                "validate_wai2_fixture_bundle",
            ) as validate_fixture:
                result = build_fixture.main([
                    "--derived-data",
                    str(derived_data),
                ])

            self.assertEqual(result, 0)
            run.assert_called_once()
            self.assertIs(run.call_args.kwargs["check"], True)
            validate_wai2.assert_called_once_with(app.resolve())
            validate_fixture.assert_called_once_with(app.resolve())


if __name__ == "__main__":
    unittest.main()
