#!/usr/bin/env python3
import argparse
import os
import subprocess
import sys
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

import build_wai2_upgrade_fixture
import build_wai3
import wai2_invariant_gate
import wai3_release_gate
import wai3_upgrade_gate


class WAI3LocalVerificationError(Exception):
    pass


@dataclass(frozen=True)
class WAI3LocalVerificationPaths:
    root: Path

    @property
    def normal_tests(self) -> Path:
        return self.root / "normal-tests"

    @property
    def normal_result(self) -> Path:
        return self.root / "normal-tests.xcresult"

    @property
    def secure_ui_tests(self) -> Path:
        return self.root / "secure-ui-tests"

    @property
    def secure_ui_result(self) -> Path:
        return self.root / "secure-ui-tests.xcresult"

    @property
    def wai2_upgrade_fixture(self) -> Path:
        return self.root / "wai2-upgrade-fixture"

    @property
    def wai3_simulator_release(self) -> Path:
        return self.root / "wai3-release-simulator"

    @property
    def wai3_device_release(self) -> Path:
        return self.root / "wai3-release-device"


def make_normal_test_command(
    project_root: Path,
    paths: WAI3LocalVerificationPaths,
    destination: str,
) -> list[str]:
    # This gate deliberately exercises the untouched WAI 2.2 default build.
    return [
        "xcodebuild",
        "test",
        "-quiet",
        "-project",
        str(project_root / "WAI.xcodeproj"),
        "-scheme",
        "WAI",
        "-configuration",
        "Debug",
        "-destination",
        destination,
        "-derivedDataPath",
        str(paths.normal_tests),
        "-resultBundlePath",
        str(paths.normal_result),
        "-disableAutomaticPackageResolution",
        "-parallel-testing-enabled",
        "NO",
    ]


def make_secure_ui_test_command(
    project_root: Path,
    paths: WAI3LocalVerificationPaths,
    destination: str,
    configuration: build_wai3.WAI3PublicBuildConfiguration,
) -> list[str]:
    return [
        "xcodebuild",
        "test",
        "-quiet",
        "-project",
        str(project_root / "WAI.xcodeproj"),
        "-scheme",
        "WAI",
        "-configuration",
        "Debug",
        "-destination",
        destination,
        "-derivedDataPath",
        str(paths.secure_ui_tests),
        "-resultBundlePath",
        str(paths.secure_ui_result),
        "-disableAutomaticPackageResolution",
        "-parallel-testing-enabled",
        "NO",
        "-only-testing:WAIUITests/WAIUITests/testSecureEntryPointExposesPrivacyPolicy",
        "-only-testing:WAIUITests/WAIUITests/testApprovedFixtureCoversCrewWorkspace",
        "-only-testing:WAIUITests/WAIUITests/testApprovedFixtureSupportsDarkAccessibilityContent",
        *configuration.xcode_build_settings(),
    ]


def make_python_test_command(project_root: Path) -> list[str]:
    return [
        sys.executable,
        "-m",
        "unittest",
        "discover",
        "-s",
        str(project_root / "scripts/tests"),
        "-p",
        "test_*.py",
    ]


def default_artifacts_directory() -> Path:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return Path("/tmp") / f"WAI3LocalVerification-{stamp}"


def validate_simulator_id(value: str) -> str:
    try:
        parsed = uuid.UUID(value)
    except ValueError as error:
        raise WAI3LocalVerificationError(
            "Simulator ID must be a valid UUID"
        ) from error
    return str(parsed).upper()


def prepare_artifacts_directory(path: Path) -> Path:
    resolved = path.expanduser().resolve()
    try:
        resolved.mkdir(parents=True, exist_ok=False)
    except FileExistsError as error:
        raise WAI3LocalVerificationError(
            f"Artifacts directory already exists: {resolved}"
        ) from error
    return resolved


def run_command(
    command: list[str],
    *,
    project_root: Path,
) -> None:
    subprocess.run(command, cwd=project_root, check=True)


def run_verification(
    *,
    project_root: Path,
    artifacts_root: Path,
    simulator_id: str,
    configuration: build_wai3.WAI3PublicBuildConfiguration,
) -> WAI3LocalVerificationPaths:
    project_root = project_root.resolve()
    paths = WAI3LocalVerificationPaths(root=artifacts_root)
    simulator_destination = f"platform=iOS Simulator,id={simulator_id}"

    build_wai3.validate_source_info_plist(project_root)

    print("[1/7] Python validation and security tests", flush=True)
    run_command(
        make_python_test_command(project_root),
        project_root=project_root,
    )

    print("[2/7] Normal WAI 2.2 regression and invariant", flush=True)
    run_command(
        make_normal_test_command(
            project_root,
            paths,
            simulator_destination,
        ),
        project_root=project_root,
    )
    normal_app = (
        paths.normal_tests
        / "Build/Products/Debug-iphonesimulator/WAI.app"
    )
    wai2_invariant_gate.validate_app_bundle(normal_app)

    print("[3/7] WAI 3 secure-entry and approved-workspace UI", flush=True)
    run_command(
        make_secure_ui_test_command(
            project_root,
            paths,
            simulator_destination,
            configuration,
        ),
        project_root=project_root,
    )

    print("[4/7] WAI 2.2 Release upgrade fixture", flush=True)
    run_command(
        build_wai2_upgrade_fixture.make_build_command(
            project_root,
            paths.wai2_upgrade_fixture,
            "generic/platform=iOS Simulator",
        ),
        project_root=project_root,
    )
    wai2_app = build_wai2_upgrade_fixture.built_app_path(
        paths.wai2_upgrade_fixture
    )
    wai2_invariant_gate.validate_app_bundle(wai2_app)
    wai3_upgrade_gate.validate_wai2_fixture_bundle(wai2_app)

    print("[5/7] WAI 3 simulator Release boundary", flush=True)
    run_command(
        build_wai3.make_build_command(
            project_root,
            paths.wai3_simulator_release,
            "generic/platform=iOS Simulator",
            configuration,
        ),
        project_root=project_root,
    )
    wai3_simulator_app = build_wai3.built_app_path(
        paths.wai3_simulator_release
    )
    wai3_release_gate.validate_app_bundle(wai3_simulator_app)

    print("[6/7] WAI 3 unsigned iPhone Release boundary", flush=True)
    run_command(
        build_wai3.make_build_command(
            project_root,
            paths.wai3_device_release,
            "generic/platform=iOS",
            configuration,
            device_build=True,
        ),
        project_root=project_root,
    )
    wai3_device_app = build_wai3.built_app_path(
        paths.wai3_device_release,
        device_build=True,
    )
    wai3_release_gate.validate_app_bundle(wai3_device_app)

    print("[7/7] Release-to-Release simulator upgrade", flush=True)
    wai3_upgrade_gate.run_upgrade_gate(
        simulator_id=simulator_id,
        wai2_app=wai2_app,
        wai3_app=wai3_simulator_app,
    )
    return paths


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Run every local WAI 2.2/WAI 3 release gate without upload, "
            "deployment, GitHub access, or physical-device installation."
        )
    )
    parser.add_argument("--simulator-id", required=True)
    parser.add_argument(
        "--project-root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
    )
    parser.add_argument(
        "--artifacts-dir",
        type=Path,
        default=None,
        help="New directory for build and test artifacts (must not exist).",
    )
    arguments = parser.parse_args(argv)

    try:
        simulator_id = validate_simulator_id(arguments.simulator_id)
        artifacts_root = prepare_artifacts_directory(
            arguments.artifacts_dir or default_artifacts_directory()
        )
        configuration = build_wai3.WAI3PublicBuildConfiguration.from_environment(
            os.environ
        )
        paths = run_verification(
            project_root=arguments.project_root,
            artifacts_root=artifacts_root,
            simulator_id=simulator_id,
            configuration=configuration,
        )
    except (
        WAI3LocalVerificationError,
        build_wai3.WAI3BuildConfigurationError,
        wai2_invariant_gate.WAI2InvariantError,
        wai3_release_gate.WAI3ReleaseGateError,
        wai3_upgrade_gate.WAI3UpgradeGateError,
        subprocess.CalledProcessError,
        OSError,
    ) as error:
        parser.error(str(error))

    print(f"All local WAI 3 gates passed: {paths.root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
