#!/usr/bin/env python3
import argparse
import ipaddress
import plistlib
import re
from pathlib import Path
from urllib.parse import urlparse


class WAI3ReleaseGateError(Exception):
    pass


LEGACY_URL_KEYS = {
    "WAITransportRulesURL",
    "WAIHotelMapURL",
    "WAIWhatsNewURL",
    "WAIRemoteTransportRulesURL",
    "WAIRemoteHotelMapURL",
    "WAIRemoteWhatsNewURL",
}
OPERATIONAL_JSON_PATTERNS = (
    re.compile(r"^wai_transport_rules.*\.json$", re.IGNORECASE),
    re.compile(r"^wai_hotel_map.*\.json$", re.IGNORECASE),
    re.compile(r"^wai_whats_new.*\.json$", re.IGNORECASE),
)
FORBIDDEN_BINARY_MARKERS = (
    b"raw.githubusercontent.com",
    b"github.com/Jopepo/WAI",
    b"sb_secret_",
    b"SUPABASE_SERVICE_ROLE_KEY",
    b"APPLE_PRIVATE_KEY",
    b"-----BEGIN PRIVATE KEY-----",
    b"wai3-approved-ui-test-fixture",
    b"Local UI test fixture",
    b"wai2-upgrade-test-fixture",
    b"WAI2_UPGRADE_TEST_FIXTURE",
    b"wai.debug.upgradeFixtureSeeded",
    b"wai.debug.upgradeFixtureFailure",
)
REQUIRED_PRIVACY_API_REASONS = {
    "NSPrivacyAccessedAPICategoryUserDefaults": {"CA92.1"},
    "NSPrivacyAccessedAPICategoryFileTimestamp": {"C617.1"},
}
REQUIRED_COLLECTED_DATA_TYPES = {
    "NSPrivacyCollectedDataTypeName",
    "NSPrivacyCollectedDataTypeEmailAddress",
    "NSPrivacyCollectedDataTypeUserID",
}


def validate_app_bundle(
    app_bundle: Path,
    expected_bundle_identifier: str | None = None,
) -> None:
    errors = release_gate_errors(app_bundle, expected_bundle_identifier)
    if errors:
        raise WAI3ReleaseGateError("\n".join(errors))


def release_gate_errors(
    app_bundle: Path,
    expected_bundle_identifier: str | None = None,
) -> list[str]:
    app_bundle = app_bundle.resolve()
    errors: list[str] = []
    if not app_bundle.is_dir() or app_bundle.suffix != ".app":
        return ["Expected a built .app bundle directory"]

    info_path = app_bundle / "Info.plist"
    try:
        with info_path.open("rb") as handle:
            info = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException):
        return ["Info.plist is missing or invalid"]

    bundle_identifier = info.get("CFBundleIdentifier")
    if not _valid_bundle_identifier(bundle_identifier):
        errors.append("CFBundleIdentifier is missing or invalid")
    elif (
        expected_bundle_identifier is not None
        and bundle_identifier != expected_bundle_identifier
    ):
        errors.append(
            "CFBundleIdentifier does not match the expected build identifier"
        )

    if info.get("WAI3SecureModeEnabled") is not True:
        errors.append("WAI3SecureModeEnabled must be true")

    compatibility = info.get("WAI3CompatibilityVersion")
    if not isinstance(compatibility, str) or not _valid_version(
        compatibility
    ):
        errors.append("WAI3CompatibilityVersion must be a 3.x version")

    if not _valid_supabase_url(info.get("WAISupabaseURL")):
        errors.append("WAISupabaseURL must be an exact HTTPS Supabase URL")

    publishable_key = info.get("WAISupabasePublishableKey")
    if (
        not isinstance(publishable_key, str)
        or not publishable_key.startswith("sb_publishable_")
        or not 24 <= len(publishable_key.encode("utf-8")) <= 512
        or any(character.isspace() for character in publishable_key)
    ):
        errors.append("WAISupabasePublishableKey is missing or invalid")

    approval_email = info.get("WAIApprovalEmail")
    if (
        not isinstance(approval_email, str)
        or not _valid_email(approval_email)
    ):
        errors.append("WAIApprovalEmail is missing or invalid")

    if not _valid_privacy_policy_url(info.get("WAIPrivacyPolicyURL")):
        errors.append("WAIPrivacyPolicyURL must be a safe public HTTPS URL")

    legacy_keys = sorted(LEGACY_URL_KEYS.intersection(info))
    if legacy_keys:
        errors.append(
            "Legacy public data URL keys remain: " + ", ".join(legacy_keys)
        )

    for key, value in info.items():
        normalized_key = str(key).lower()
        if "secret" in normalized_key or "service_role" in normalized_key:
            errors.append(f"Secret-like Info.plist key remains: {key}")
        if isinstance(value, str) and _contains_public_repository_url(value):
            errors.append(f"Public repository URL remains in Info.plist: {key}")

    errors.extend(_privacy_manifest_errors(app_bundle))

    operational_files = sorted(
        str(path.relative_to(app_bundle))
        for path in app_bundle.rglob("*")
        if path.is_file()
        and any(pattern.match(path.name) for pattern in OPERATIONAL_JSON_PATTERNS)
    )
    if operational_files:
        errors.append(
            "Operational JSON remains in app bundle: "
            + ", ".join(operational_files)
        )

    marker_hits: set[str] = set()
    for path in app_bundle.rglob("*"):
        if not path.is_file() or path == info_path:
            continue
        try:
            data = path.read_bytes()
        except OSError:
            errors.append(
                f"Could not inspect bundle file: {path.relative_to(app_bundle)}"
            )
            continue
        for marker in FORBIDDEN_BINARY_MARKERS:
            if marker.lower() in data.lower():
                marker_hits.add(marker.decode("ascii"))
    if marker_hits:
        errors.append(
            "Forbidden public/secret marker remains in app bundle: "
            + ", ".join(sorted(marker_hits))
        )

    return errors


def _valid_supabase_url(value: object) -> bool:
    if not isinstance(value, str):
        return False
    parsed = urlparse(value)
    try:
        port = parsed.port
    except ValueError:
        return False
    if (
        parsed.scheme != "https"
        or parsed.username is not None
        or parsed.password is not None
        or port is not None
        or parsed.path not in ("", "/")
        or parsed.params
        or parsed.query
        or parsed.fragment
        or parsed.hostname is None
        or not parsed.hostname.endswith(".supabase.co")
    ):
        return False
    project_ref = parsed.hostname.removesuffix(".supabase.co")
    return bool(re.fullmatch(r"[a-z0-9]{8,40}", project_ref))


def _valid_bundle_identifier(value: object) -> bool:
    return (
        isinstance(value, str)
        and 3 <= len(value.encode("utf-8")) <= 255
        and re.fullmatch(
            r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+",
            value,
        )
        is not None
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


def _valid_privacy_policy_url(value: object) -> bool:
    if not isinstance(value, str):
        return False
    if len(value.encode("utf-8")) > 2_048:
        return False
    parsed = urlparse(value)
    try:
        port = parsed.port
    except ValueError:
        return False
    hostname = parsed.hostname
    if hostname is None:
        return False
    try:
        ipaddress.ip_address(hostname)
        return False
    except ValueError:
        pass
    labels = hostname.lower().split(".")
    valid_hostname = (
        len(labels) >= 2
        and not hostname.lower().endswith((".local", ".internal"))
        and all(
            1 <= len(label.encode("ascii", errors="ignore")) <= 63
            and re.fullmatch(r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?", label)
            for label in labels
        )
        and any(character.isalpha() for character in labels[-1])
    )
    return (
        parsed.scheme == "https"
        and parsed.username is None
        and parsed.password is None
        and port is None
        and valid_hostname
        and not parsed.params
        and not parsed.query
        and not parsed.fragment
        and parsed.path not in ("", "/")
    )


def _privacy_manifest_errors(app_bundle: Path) -> list[str]:
    privacy_path = app_bundle / "PrivacyInfo.xcprivacy"
    try:
        with privacy_path.open("rb") as handle:
            manifest = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException):
        return ["PrivacyInfo.xcprivacy is missing or invalid"]
    if not isinstance(manifest, dict):
        return ["PrivacyInfo.xcprivacy root must be a dictionary"]

    errors: list[str] = []
    if manifest.get("NSPrivacyTracking") is not False:
        errors.append("Privacy manifest must explicitly disable tracking")
    if manifest.get("NSPrivacyTrackingDomains") not in (None, []):
        errors.append("Privacy manifest contains tracking domains")

    accessed: dict[str, set[str]] = {}
    accessed_items = manifest.get("NSPrivacyAccessedAPITypes", [])
    if not isinstance(accessed_items, list):
        accessed_items = []
        errors.append("Privacy accessed API declarations must be an array")
    for item in accessed_items:
        if not isinstance(item, dict):
            errors.append("Privacy accessed API declaration is invalid")
            continue
        category = item.get("NSPrivacyAccessedAPIType")
        reasons = item.get("NSPrivacyAccessedAPITypeReasons")
        if isinstance(category, str) and isinstance(reasons, list):
            accessed[category] = {value for value in reasons if isinstance(value, str)}
    for category, required_reasons in REQUIRED_PRIVACY_API_REASONS.items():
        if not required_reasons.issubset(accessed.get(category, set())):
            errors.append(
                f"Privacy manifest is missing required reason for {category}"
            )

    collected: dict[str, dict] = {}
    collected_items = manifest.get("NSPrivacyCollectedDataTypes", [])
    if not isinstance(collected_items, list):
        collected_items = []
        errors.append("Privacy collected data declarations must be an array")
    for item in collected_items:
        if isinstance(item, dict) and isinstance(
            item.get("NSPrivacyCollectedDataType"), str
        ):
            collected[item["NSPrivacyCollectedDataType"]] = item
    for data_type in sorted(REQUIRED_COLLECTED_DATA_TYPES):
        item = collected.get(data_type)
        if item is None:
            errors.append(f"Privacy manifest is missing collected type {data_type}")
            continue
        if item.get("NSPrivacyCollectedDataTypeLinked") is not True:
            errors.append(f"Collected type must be linked to user: {data_type}")
        if item.get("NSPrivacyCollectedDataTypeTracking") is not False:
            errors.append(f"Collected type must not be used for tracking: {data_type}")
        purposes = item.get("NSPrivacyCollectedDataTypePurposes")
        if not isinstance(purposes, list) or (
            "NSPrivacyCollectedDataTypePurposeAppFunctionality" not in purposes
        ):
            errors.append(f"Collected type lacks app functionality purpose: {data_type}")
    return errors


def _contains_public_repository_url(value: str) -> bool:
    lowered = value.lower()
    return "raw.githubusercontent.com" in lowered or "github.com/jopepo/wai" in lowered


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Fail unless a built WAI 3 app respects the private-data boundary."
    )
    parser.add_argument("app_bundle", type=Path)
    parser.add_argument("--expected-bundle-identifier")
    arguments = parser.parse_args(argv)
    try:
        validate_app_bundle(
            arguments.app_bundle,
            expected_bundle_identifier=arguments.expected_bundle_identifier,
        )
    except WAI3ReleaseGateError as error:
        parser.error(str(error))
    print("WAI 3 privacy release gate passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
