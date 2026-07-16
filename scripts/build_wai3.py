#!/usr/bin/env python3
import argparse
import os
import plistlib
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping

import wai3_release_gate


class WAI3BuildConfigurationError(Exception):
    pass


OPERATIONAL_JSON_FILES = (
    "wai_transport_rules_current.json",
    "wai_transport_rules_rev73.json",
    "wai_hotel_map_current.json",
    "wai_hotel_map_rev51.json",
    "wai_whats_new_current.json",
)


@dataclass(frozen=True)
class WAI3PublicBuildConfiguration:
    supabase_url: str
    supabase_publishable_key: str
    approval_email: str
    privacy_policy_url: str
    compatibility_version: str
    marketing_version: str
    build_number: str

    @classmethod
    def from_environment(
        cls,
        environment: Mapping[str, str],
    ) -> "WAI3PublicBuildConfiguration":
        required = {
            "supabase_url": "WAI3_SUPABASE_URL",
            "supabase_publishable_key": "WAI3_SUPABASE_PUBLISHABLE_KEY",
            "approval_email": "WAI3_APPROVAL_EMAIL",
            "privacy_policy_url": "WAI3_PRIVACY_POLICY_URL",
        }
        values: dict[str, str] = {}
        missing: list[str] = []
        for field, variable in required.items():
            value = environment.get(variable, "").strip()
            if not value:
                missing.append(variable)
            values[field] = value
        if missing:
            raise WAI3BuildConfigurationError(
                "Missing public WAI 3 build settings: " + ", ".join(missing)
            )

        configuration = cls(
            **values,
            compatibility_version=environment.get(
                "WAI3_COMPATIBILITY_VERSION", "3.0"
            ).strip(),
            marketing_version=environment.get(
                "WAI3_MARKETING_VERSION", "3.0"
            ).strip(),
            build_number=environment.get("WAI3_BUILD_NUMBER", "17").strip(),
        )
        configuration.validate()
        return configuration

    def validate(self) -> None:
        if not wai3_release_gate._valid_supabase_url(self.supabase_url):
            raise WAI3BuildConfigurationError(
                "WAI3_SUPABASE_URL must be an exact HTTPS Supabase URL"
            )
        if (
            not self.supabase_publishable_key.startswith("sb_publishable_")
            or not 24 <= len(self.supabase_publishable_key.encode("utf-8")) <= 512
            or any(character.isspace() for character in self.supabase_publishable_key)
        ):
            raise WAI3BuildConfigurationError(
                "WAI3_SUPABASE_PUBLISHABLE_KEY is invalid"
            )
        if not _valid_email(self.approval_email):
            raise WAI3BuildConfigurationError("WAI3_APPROVAL_EMAIL is invalid")
        if not wai3_release_gate._valid_privacy_policy_url(
            self.privacy_policy_url
        ):
            raise WAI3BuildConfigurationError(
                "WAI3_PRIVACY_POLICY_URL must be a safe public HTTPS URL"
            )
        if not _valid_version(self.compatibility_version):
            raise WAI3BuildConfigurationError(
                "WAI3_COMPATIBILITY_VERSION must be a 3.x version"
            )
        if not _valid_version(self.marketing_version):
            raise WAI3BuildConfigurationError(
                "WAI3_MARKETING_VERSION must be a 3.x version"
            )
        if not re.fullmatch(r"[1-9]\d*", self.build_number):
            raise WAI3BuildConfigurationError(
                "WAI3_BUILD_NUMBER must be a positive integer"
            )

    def xcode_build_settings(self) -> list[str]:
        return [
            "WAI_APP_INFO_PLIST=WAI/WAI3-Info.plist",
            f"WAI_APP_MARKETING_VERSION={self.marketing_version}",
            f"WAI_APP_BUILD_NUMBER={self.build_number}",
            "WAI_APP_EXCLUDED_SOURCE_FILE_NAMES="
            + " ".join(OPERATIONAL_JSON_FILES),
            f"WAI3_SUPABASE_URL={self.supabase_url}",
            "WAI3_SUPABASE_PUBLISHABLE_KEY="
            + self.supabase_publishable_key,
            f"WAI3_APPROVAL_EMAIL={self.approval_email}",
            f"WAI3_PRIVACY_POLICY_URL={self.privacy_policy_url}",
            f"WAI3_COMPATIBILITY_VERSION={self.compatibility_version}",
        ]


def make_build_command(
    project_root: Path,
    derived_data: Path,
    destination: str,
    configuration: WAI3PublicBuildConfiguration,
    device_build: bool = False,
) -> list[str]:
    command = [
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
        *configuration.xcode_build_settings(),
    ]
    if device_build:
        command.append("CODE_SIGNING_ALLOWED=NO")
    return command


def built_app_path(derived_data: Path, device_build: bool = False) -> Path:
    platform_directory = "Release-iphoneos" if device_build else (
        "Release-iphonesimulator"
    )
    return derived_data / f"Build/Products/{platform_directory}/WAI.app"


def validate_source_info_plist(project_root: Path) -> None:
    info_path = project_root / "WAI/WAI3-Info.plist"
    try:
        with info_path.open("rb") as handle:
            info = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as error:
        raise WAI3BuildConfigurationError(
            "WAI3-Info.plist is missing or invalid"
        ) from error
    if info.get("WAI3SecureModeEnabled") is not True:
        raise WAI3BuildConfigurationError(
            "WAI3-Info.plist must enable secure mode"
        )
    legacy_keys = wai3_release_gate.LEGACY_URL_KEYS.intersection(info)
    if legacy_keys:
        raise WAI3BuildConfigurationError(
            "WAI3-Info.plist contains legacy public URL keys"
        )


def _valid_email(value: str) -> bool:
    if (
        not 3 <= len(value.encode("utf-8")) <= 254
        or any(character.isspace() for character in value)
    ):
        return False
    parts = value.split("@")
    return (
        len(parts) == 2
        and bool(parts[0])
        and "." in parts[1]
        and all(parts[1].split("."))
    )


def _valid_version(value: str) -> bool:
    return (
        3 <= len(value.encode("utf-8")) <= 32
        and re.fullmatch(r"3(?:\.\d{1,9}){1,2}", value) is not None
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Build and verify a local WAI 3 app. "
            "This command never uploads or installs the app."
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
        default=Path("/tmp/WAI3SecureBuild"),
    )
    parser.add_argument(
        "--destination",
        default="generic/platform=iOS Simulator",
    )
    parser.add_argument(
        "--device",
        action="store_true",
        help="Compile an unsigned generic iPhone build instead of a simulator build.",
    )
    arguments = parser.parse_args(argv)

    project_root = arguments.project_root.resolve()
    derived_data = arguments.derived_data.resolve()
    try:
        configuration = WAI3PublicBuildConfiguration.from_environment(os.environ)
        validate_source_info_plist(project_root)
        subprocess.run(
            make_build_command(
                project_root,
                derived_data,
                "generic/platform=iOS"
                if arguments.device else arguments.destination,
                configuration,
                device_build=arguments.device,
            ),
            cwd=project_root,
            check=True,
        )
        app_bundle = built_app_path(
            derived_data,
            device_build=arguments.device,
        )
        wai3_release_gate.validate_app_bundle(app_bundle)
    except (
        WAI3BuildConfigurationError,
        wai3_release_gate.WAI3ReleaseGateError,
        subprocess.CalledProcessError,
    ) as error:
        parser.error(str(error))

    print(f"Verified local WAI 3 app: {app_bundle}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
