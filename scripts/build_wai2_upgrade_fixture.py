#!/usr/bin/env python3
import argparse
import subprocess
from pathlib import Path

import wai2_invariant_gate
import wai3_upgrade_gate


FIXTURE_CONDITION = "WAI_UPGRADE_TEST_FIXTURE"


def make_build_command(
    project_root: Path,
    derived_data: Path,
    destination: str,
) -> list[str]:
    return [
        "xcodebuild",
        "build",
        "-quiet",
        "-project",
        str(project_root / "WAI.xcodeproj"),
        "-scheme",
        "WAI",
        "-configuration",
        "Release",
        "-destination",
        destination,
        "-derivedDataPath",
        str(derived_data),
        "-disableAutomaticPackageResolution",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS="
        f"$(inherited) {FIXTURE_CONDITION}",
    ]


def built_app_path(derived_data: Path) -> Path:
    return derived_data / "Build/Products/Release-iphonesimulator/WAI.app"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Build a local WAI 2.2 Release fixture for the WAI 3 simulator "
            "upgrade gate. This command never uploads or installs the app."
        )
    )
    parser.add_argument(
        "--project-root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
    )
    parser.add_argument(
        "--derived-data",
        type=Path,
        default=Path("/tmp/WAI2UpgradeReleaseFixture"),
    )
    parser.add_argument(
        "--destination",
        default="generic/platform=iOS Simulator",
    )
    arguments = parser.parse_args(argv)

    project_root = arguments.project_root.resolve()
    derived_data = arguments.derived_data.resolve()
    try:
        subprocess.run(
            make_build_command(
                project_root,
                derived_data,
                arguments.destination,
            ),
            cwd=project_root,
            check=True,
        )
        app_bundle = built_app_path(derived_data)
        wai2_invariant_gate.validate_app_bundle(app_bundle)
        wai3_upgrade_gate.validate_wai2_fixture_bundle(app_bundle)
    except (
        subprocess.CalledProcessError,
        wai2_invariant_gate.WAI2InvariantError,
        wai3_upgrade_gate.WAI3UpgradeGateError,
    ) as error:
        parser.error(str(error))

    print(f"Verified local WAI 2.2 upgrade fixture: {app_bundle}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
