#!/usr/bin/env python3
import argparse
import json
import os
import plistlib
import sqlite3
import subprocess
import time
from pathlib import Path

import wai2_invariant_gate
import wai3_release_gate


class WAI3UpgradeGateError(Exception):
    pass


LEGACY_SENSITIVE_KEYS = {
    "wai.calculationHistory",
    "wai.lastCalculation",
    "wai.hotelStays",
}
LEGACY_CACHE_FILES = {
    "wai_transport_rules_current.json",
    "wai_hotel_map_current.json",
    "wai_whats_new_current.json",
}
SEED_KEY = "wai.debug.upgradeFixtureSeeded"
FAILURE_KEY = "wai.debug.upgradeFixtureFailure"
SENTINEL_KEY = "wai.debug.upgradeSentinel"
PRESERVED_REFERENCE_KEY = "wai.timeInputReference"
UNRELATED_CACHE_FILE = "wai-upgrade-unrelated.cache"
WAI2_FIXTURE_BINARY_MARKERS = {
    b"WAI2_UPGRADE_TEST_FIXTURE",
    b"wai.debug.upgradeFixtureSeeded",
}


def load_info(app_bundle: Path) -> dict:
    try:
        with (app_bundle / "Info.plist").open("rb") as handle:
            return plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as error:
        raise WAI3UpgradeGateError(
            f"Invalid app Info.plist: {app_bundle}"
        ) from error


def validate_wai2_fixture_bundle(app_bundle: Path) -> None:
    if (app_bundle / "WAI.debug.dylib").exists():
        raise WAI3UpgradeGateError(
            "WAI 2 upgrade fixture must use the Release configuration"
        )
    info = load_info(app_bundle)
    executable_name = info.get("CFBundleExecutable")
    if not isinstance(executable_name, str) or not executable_name:
        raise WAI3UpgradeGateError(
            "WAI 2 fixture has no valid executable name"
        )
    try:
        executable = (app_bundle / executable_name).read_bytes()
    except OSError as error:
        raise WAI3UpgradeGateError(
            "WAI 2 fixture executable is missing"
        ) from error
    missing = sorted(
        marker.decode("ascii")
        for marker in WAI2_FIXTURE_BINARY_MARKERS
        if marker not in executable
    )
    if missing:
        raise WAI3UpgradeGateError(
            "WAI 2 Release fixture markers are missing: "
            + ", ".join(missing)
        )


def validate_app_pair(wai2_app: Path, wai3_app: Path) -> str:
    try:
        wai2_invariant_gate.validate_app_bundle(wai2_app)
        wai3_release_gate.validate_app_bundle(wai3_app)
    except (
        wai2_invariant_gate.WAI2InvariantError,
        wai3_release_gate.WAI3ReleaseGateError,
    ) as error:
        raise WAI3UpgradeGateError(str(error)) from error

    wai2_info = load_info(wai2_app)
    wai3_info = load_info(wai3_app)
    validate_wai2_fixture_bundle(wai2_app)
    wai2_identifier = wai2_info.get("CFBundleIdentifier")
    wai3_identifier = wai3_info.get("CFBundleIdentifier")
    if (
        not isinstance(wai2_identifier, str)
        or not wai2_identifier
        or wai2_identifier != wai3_identifier
    ):
        raise WAI3UpgradeGateError(
            "WAI 2 and WAI 3 must use the same non-empty bundle identifier"
        )
    return wai2_identifier


def preferences_path(data_container: Path, bundle_identifier: str) -> Path:
    return (
        data_container
        / "Library"
        / "Preferences"
        / f"{bundle_identifier}.plist"
    )


def read_preferences(
    data_container: Path,
    bundle_identifier: str,
) -> dict:
    path = preferences_path(data_container, bundle_identifier)
    try:
        with path.open("rb") as handle:
            value = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as error:
        raise WAI3UpgradeGateError(
            f"Unable to read app preferences: {path}"
        ) from error
    if not isinstance(value, dict):
        raise WAI3UpgradeGateError("App preferences are not a dictionary")
    return value


def legacy_fixture_errors(
    data_container: Path,
    bundle_identifier: str,
) -> list[str]:
    preferences = read_preferences(data_container, bundle_identifier)
    errors: list[str] = []
    failure = preferences.get(FAILURE_KEY)
    if isinstance(failure, str) and failure:
        errors.append(f"Legacy fixture failed inside the app: {failure}")
    for key in sorted(LEGACY_SENSITIVE_KEYS):
        value = preferences.get(key)
        if not isinstance(value, bytes) or not value:
            errors.append(f"Legacy fixture is missing UserDefaults data: {key}")
    if preferences.get(SEED_KEY) is not True:
        errors.append("Legacy fixture seed marker is missing")
    if preferences.get(SENTINEL_KEY) != "preserve":
        errors.append("Legacy fixture preference sentinel is missing")
    if preferences.get(PRESERVED_REFERENCE_KEY) != "utc":
        errors.append("Legacy time-reference preference is missing")

    caches = data_container / "Library" / "Caches"
    for file_name in sorted(LEGACY_CACHE_FILES):
        path = caches / file_name
        if not path.is_file() or path.stat().st_size == 0:
            errors.append(f"Legacy operational cache is missing: {file_name}")
    unrelated = caches / UNRELATED_CACHE_FILE
    if not unrelated.is_file() or unrelated.read_bytes() != b"preserve":
        errors.append("Unrelated cache sentinel is missing")
    return errors


def upgraded_state_errors(
    data_container: Path,
    bundle_identifier: str,
) -> list[str]:
    preferences = read_preferences(data_container, bundle_identifier)
    errors: list[str] = []
    for key in sorted(LEGACY_SENSITIVE_KEYS):
        if key in preferences:
            errors.append(f"Legacy personal data survived upgrade: {key}")
    if preferences.get(SEED_KEY) is not True:
        errors.append("Upgrade seed marker was unexpectedly removed")
    if preferences.get(SENTINEL_KEY) != "preserve":
        errors.append("Unrelated preference was removed during upgrade")
    if preferences.get(PRESERVED_REFERENCE_KEY) != "utc":
        errors.append("Non-sensitive time-reference preference was removed")

    caches = data_container / "Library" / "Caches"
    for file_name in sorted(LEGACY_CACHE_FILES):
        if (caches / file_name).exists():
            errors.append(f"Legacy operational cache survived: {file_name}")
    unrelated = caches / UNRELATED_CACHE_FILE
    if not unrelated.is_file() or unrelated.read_bytes() != b"preserve":
        errors.append("Unrelated cache was removed during upgrade")
    return errors


def run_simctl(
    arguments: list[str],
    *,
    check: bool = True,
    environment: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    process_environment = os.environ.copy()
    if environment:
        process_environment.update(environment)
    completed = subprocess.run(
        ["xcrun", "simctl", *arguments],
        check=False,
        capture_output=True,
        text=True,
        env=process_environment,
    )
    if check and completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip()
        raise WAI3UpgradeGateError(
            f"simctl {' '.join(arguments)} failed: {detail}"
        )
    return completed


def simulator_record(simulator_id: str) -> dict:
    completed = run_simctl(["list", "devices", "--json"])
    try:
        devices = json.loads(completed.stdout).get("devices", {})
    except json.JSONDecodeError as error:
        raise WAI3UpgradeGateError("simctl returned invalid JSON") from error
    for runtime_devices in devices.values():
        for device in runtime_devices:
            if device.get("udid") == simulator_id:
                return device
    raise WAI3UpgradeGateError(f"Unknown simulator: {simulator_id}")


def ensure_booted(simulator_id: str) -> bool:
    record = simulator_record(simulator_id)
    was_booted = record.get("state") == "Booted"
    if not was_booted:
        run_simctl(["boot", simulator_id])
    run_simctl(["bootstatus", simulator_id, "-b"])
    return not was_booted


def restart_simulator(simulator_id: str) -> None:
    run_simctl(["shutdown", simulator_id])
    run_simctl(["boot", simulator_id])
    run_simctl(["bootstatus", simulator_id, "-b"])


def data_container(simulator_id: str, bundle_identifier: str) -> Path:
    completed = run_simctl(
        ["get_app_container", simulator_id, bundle_identifier, "data"]
    )
    path = Path(completed.stdout.strip())
    if not path.is_dir():
        raise WAI3UpgradeGateError("App data container is unavailable")
    return path


def wait_for_legacy_fixture(
    container: Path,
    bundle_identifier: str,
    timeout: float = 8,
) -> None:
    deadline = time.monotonic() + timeout
    last_errors: list[str] = []
    while time.monotonic() < deadline:
        try:
            last_errors = legacy_fixture_errors(container, bundle_identifier)
        except WAI3UpgradeGateError as error:
            last_errors = [str(error)]
        if not last_errors:
            return
        time.sleep(0.25)
    raise WAI3UpgradeGateError("; ".join(last_errors))


def simulator_data_path(simulator_id: str) -> Path:
    record = simulator_record(simulator_id)
    raw_path = record.get("dataPath")
    if isinstance(raw_path, str) and raw_path:
        path = Path(raw_path)
    else:
        path = (
            Path.home()
            / "Library"
            / "Developer"
            / "CoreSimulator"
            / "Devices"
            / simulator_id
            / "data"
        )
    if not path.is_dir():
        raise WAI3UpgradeGateError("Simulator data directory is unavailable")
    return path


def calendar_permission_rows(
    simulator_id: str,
    bundle_identifier: str,
) -> list[tuple[str, int]]:
    database = simulator_data_path(simulator_id) / "Library" / "TCC" / "TCC.db"
    if not database.is_file():
        raise WAI3UpgradeGateError("Simulator TCC database is unavailable")
    try:
        connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
        try:
            columns = {
                row[1]
                for row in connection.execute("pragma table_info(access)")
            }
            value_column = (
                "auth_value" if "auth_value" in columns else "allowed"
            )
            if value_column not in columns:
                raise WAI3UpgradeGateError(
                    "Simulator TCC schema has no authorization value"
                )
            rows = connection.execute(
                "select service, "
                + value_column
                + " from access where client = ? "
                + "and lower(service) like '%calendar%' order by service",
                (bundle_identifier,),
            ).fetchall()
        finally:
            connection.close()
    except sqlite3.Error as error:
        raise WAI3UpgradeGateError(
            "Unable to inspect simulator Calendar permission"
        ) from error
    return [(str(service), int(value)) for service, value in rows]


def run_upgrade_gate(
    simulator_id: str,
    wai2_app: Path,
    wai3_app: Path,
) -> None:
    wai2_app = wai2_app.resolve()
    wai3_app = wai3_app.resolve()
    bundle_identifier = validate_app_pair(wai2_app, wai3_app)
    booted_by_gate = ensure_booted(simulator_id)
    try:
        run_simctl(
            ["terminate", simulator_id, bundle_identifier],
            check=False,
        )
        run_simctl(
            ["uninstall", simulator_id, bundle_identifier],
            check=False,
        )
        run_simctl(["install", simulator_id, str(wai2_app)])
        run_simctl(
            [
                "launch",
                "--terminate-running-process",
                simulator_id,
                bundle_identifier,
            ],
            environment={"SIMCTL_CHILD_WAI2_UPGRADE_TEST_FIXTURE": "1"},
        )
        initial_container = data_container(simulator_id, bundle_identifier)
        wait_for_legacy_fixture(initial_container, bundle_identifier)
        run_simctl(["terminate", simulator_id, bundle_identifier])

        run_simctl(
            ["privacy", simulator_id, "grant", "calendar", bundle_identifier]
        )
        permission_before = calendar_permission_rows(
            simulator_id,
            bundle_identifier,
        )
        if not permission_before or not all(
            value in (1, 2, 3, 4) for _, value in permission_before
        ):
            raise WAI3UpgradeGateError(
                "Calendar permission was not granted before upgrade"
            )

        run_simctl(["install", simulator_id, str(wai3_app)])
        upgraded_container = data_container(simulator_id, bundle_identifier)
        wait_for_legacy_fixture(upgraded_container, bundle_identifier)
        run_simctl(
            [
                "launch",
                "--terminate-running-process",
                simulator_id,
                bundle_identifier,
            ]
        )
        time.sleep(2)
        run_simctl(["terminate", simulator_id, bundle_identifier])

        restart_simulator(simulator_id)
        upgraded_container = data_container(
            simulator_id,
            bundle_identifier,
        )

        errors = upgraded_state_errors(
            upgraded_container,
            bundle_identifier,
        )
        if errors:
            raise WAI3UpgradeGateError("; ".join(errors))

        permission_after = calendar_permission_rows(
            simulator_id,
            bundle_identifier,
        )
        if permission_after != permission_before:
            raise WAI3UpgradeGateError(
                "Calendar permission changed during upgrade"
            )
    finally:
        if booted_by_gate:
            run_simctl(["shutdown", simulator_id], check=False)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Verify a local WAI 2.2 to WAI 3 upgrade on an iOS Simulator. "
            "This command never uploads or installs to a physical device."
        )
    )
    parser.add_argument("--simulator-id", required=True)
    parser.add_argument("--wai2-app", type=Path, required=True)
    parser.add_argument("--wai3-app", type=Path, required=True)
    arguments = parser.parse_args(argv)
    try:
        run_upgrade_gate(
            simulator_id=arguments.simulator_id,
            wai2_app=arguments.wai2_app,
            wai3_app=arguments.wai3_app,
        )
    except WAI3UpgradeGateError as error:
        parser.error(str(error))
    print("WAI 2.2 to WAI 3 simulator upgrade gate passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
