#!/usr/bin/env python3
import argparse
import plistlib
from pathlib import Path


class WAI2InvariantError(Exception):
    pass


EXPECTED_URLS = {
    "WAIRemoteTransportRulesURL": (
        "https://raw.githubusercontent.com/Jopepo/WAI/main/"
        "WAI/wai_transport_rules_current.json"
    ),
    "WAIRemoteHotelMapURL": (
        "https://raw.githubusercontent.com/Jopepo/WAI/main/"
        "WAI/wai_hotel_map_current.json"
    ),
    "WAIRemoteWhatsNewURL": (
        "https://raw.githubusercontent.com/Jopepo/WAI/main/"
        "WAI/wai_whats_new_current.json"
    ),
}
EXPECTED_JSON_FILES = {
    "wai_transport_rules_current.json",
    "wai_transport_rules_rev73.json",
    "wai_hotel_map_current.json",
    "wai_hotel_map_rev51.json",
    "wai_hotel_map_rev52.json",
    "wai_whats_new_current.json",
}


def validate_app_bundle(app_bundle: Path) -> None:
    errors = invariant_errors(app_bundle)
    if errors:
        raise WAI2InvariantError("\n".join(errors))


def invariant_errors(app_bundle: Path) -> list[str]:
    app_bundle = app_bundle.resolve()
    if not app_bundle.is_dir() or app_bundle.suffix != ".app":
        return ["Expected a built .app bundle directory"]

    try:
        with (app_bundle / "Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException):
        return ["Info.plist is missing or invalid"]

    errors: list[str] = []
    if info.get("CFBundleShortVersionString") != "2.2":
        errors.append("Legacy build must remain version 2.2")
    if info.get("CFBundleVersion") != "16":
        errors.append("Legacy build must remain build 16")
    if info.get("WAI3SecureModeEnabled") not in (None, False):
        errors.append("Legacy build must not enable WAI 3 secure mode")

    for key, expected in EXPECTED_URLS.items():
        if info.get(key) != expected:
            errors.append(f"Legacy remote URL changed: {key}")

    bundled_json = {
        path.name
        for path in app_bundle.iterdir()
        if path.is_file() and path.suffix.lower() == ".json"
    }
    missing_json = sorted(EXPECTED_JSON_FILES - bundled_json)
    if missing_json:
        errors.append(
            "Legacy bundled fallback is missing: " + ", ".join(missing_json)
        )
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Verify that the local legacy WAI 2.2 build remains intact."
    )
    parser.add_argument("app_bundle", type=Path)
    arguments = parser.parse_args(argv)
    try:
        validate_app_bundle(arguments.app_bundle)
    except WAI2InvariantError as error:
        parser.error(str(error))
    print("WAI 2.2 invariant gate passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
