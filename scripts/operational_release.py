#!/usr/bin/env python3
"""Prepare and explicitly publish one atomic WAI operational-data release."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import date
from pathlib import Path
from typing import Any, Callable, Mapping
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DATA_DIR = ROOT / "WAI"
BUCKET = "wai-operational-data"
MAX_DATASET_BYTES = 1_048_576
MAX_RESPONSE_BYTES = 262_144
MAX_TRANSPORT_MINUTES = 24 * 60
MAX_STATIONS = 500
MAX_HOTELS = 500
MAX_WHATS_NEW_ITEMS = 100
MAX_GENERATION = 9_223_372_036_854_775_807
CONTRACT_VERSION = 1
MINIMUM_APP_VERSION = "3.0"
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
EXPECTED_SCHEMA_VERSIONS = {
    "hotel_map": "1.0",
    "transport_rules": "4.2",
    "whats_new": "1.0",
}


class ReleaseError(ValueError):
    """Raised when a release cannot be prepared or published safely."""


@dataclass(frozen=True)
class DatasetDefinition:
    key: str
    filename: str
    fallback_schema_version: str | None
    source_location: str


DATASETS = (
    DatasetDefinition(
        key="hotel_map",
        filename="wai_hotel_map_current.json",
        fallback_schema_version="1.0",
        source_location="root",
    ),
    DatasetDefinition(
        key="transport_rules",
        filename="wai_transport_rules_current.json",
        fallback_schema_version=None,
        source_location="source",
    ),
    DatasetDefinition(
        key="whats_new",
        filename="wai_whats_new_current.json",
        fallback_schema_version="1.0",
        source_location="source",
    ),
)


@dataclass(frozen=True)
class PreparedRelease:
    manifest: dict[str, Any]
    payloads: dict[str, bytes]


def _load_document(path: Path) -> tuple[dict[str, Any], bytes]:
    try:
        data = path.read_bytes()
    except OSError as error:
        raise ReleaseError(f"{path.name}: cannot be read: {error}") from error

    if not 1 <= len(data) <= MAX_DATASET_BYTES:
        raise ReleaseError(
            f"{path.name}: size must be between 1 and {MAX_DATASET_BYTES} bytes"
        )

    try:
        document = json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ReleaseError(f"{path.name}: invalid JSON: {error}") from error

    if not isinstance(document, dict):
        raise ReleaseError(f"{path.name}: top level must be an object")

    return document, data


def _is_integer(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _required_text(
    value: Any,
    context: str,
    *,
    maximum_bytes: int,
) -> str:
    if (
        not isinstance(value, str)
        or not value.strip()
        or len(value.encode("utf-8")) > maximum_bytes
    ):
        raise ReleaseError(f"{context} must be a non-empty bounded string")
    return value


def _optional_text(value: Any, context: str, *, maximum_bytes: int) -> None:
    if value is None:
        return
    _required_text(value, context, maximum_bytes=maximum_bytes)


def _real_iso_date(value: Any, context: str) -> None:
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", value):
        raise ReleaseError(f"{context} must be a real ISO date")
    try:
        date.fromisoformat(value)
    except ValueError as error:
        raise ReleaseError(f"{context} must be a real ISO date") from error


def _local_time(value: Any, context: str) -> None:
    if value is None:
        return
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]{2}:[0-9]{2}", value):
        raise ReleaseError(f"{context} must use HH:mm")
    hour, minute = (int(component) for component in value.split(":"))
    if not 0 <= hour <= 23 or not 0 <= minute <= 59:
        raise ReleaseError(f"{context} must use a real local time")


def _minutes(value: Any, context: str) -> int:
    if not _is_integer(value) or not 0 <= value <= MAX_TRANSPORT_MINUTES:
        raise ReleaseError(
            f"{context} must be between 0 and {MAX_TRANSPORT_MINUTES}"
        )
    return value


def _optional_boolean(value: Any, context: str) -> None:
    if value is not None and not isinstance(value, bool):
        raise ReleaseError(f"{context} must be a boolean")


def _list(value: Any, context: str, *, maximum_count: int) -> list[Any]:
    if not isinstance(value, list) or len(value) > maximum_count:
        raise ReleaseError(f"{context} must be a bounded array")
    return value


def _mapping(value: Any, context: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise ReleaseError(f"{context} must be an object")
    return value


def _source_for(
    definition: DatasetDefinition, document: Mapping[str, Any]
) -> dict[str, str]:
    raw_source: Any
    if definition.source_location == "source":
        raw_source = document.get("source")
    else:
        raw_source = {
            "document": document.get("document"),
            "revision": document.get("revision"),
            "date": document.get("date"),
        }

    if not isinstance(raw_source, Mapping):
        raise ReleaseError(f"{definition.filename}: source metadata is missing")

    source: dict[str, str] = {}
    for field in ("document", "revision", "date"):
        value = raw_source.get(field)
        if not isinstance(value, str) or not value.strip():
            raise ReleaseError(
                f"{definition.filename}: source.{field} must be non-empty"
            )
        source[field] = value.strip()

    try:
        date.fromisoformat(source["date"])
    except ValueError as error:
        raise ReleaseError(
            f"{definition.filename}: source.date must be a real ISO date"
        ) from error

    return source


def _schema_version_for(
    definition: DatasetDefinition, document: Mapping[str, Any]
) -> str:
    value = document.get("schemaVersion", definition.fallback_schema_version)
    if not isinstance(value, str) or not value.strip():
        raise ReleaseError(f"{definition.filename}: schema version is missing")
    schema_version = value.strip()
    expected = EXPECTED_SCHEMA_VERSIONS[definition.key]
    if schema_version != expected:
        raise ReleaseError(
            f"{definition.filename}: unsupported schema version {schema_version!r}; "
            f"expected {expected!r}"
        )
    return schema_version


def _validate_applicability_flags(
    value: Mapping[str, Any],
    fields: tuple[str, ...],
    context: str,
) -> None:
    for field in fields:
        _optional_boolean(value.get(field), f"{context}.{field}")
    if sum(value.get(field) is True for field in fields) > 1:
        raise ReleaseError(f"{context} has conflicting applicability flags")


def _validate_time_window(value: Mapping[str, Any], context: str) -> None:
    start = value.get("fromLocal")
    end = value.get("toLocal")
    if (start is None) != (end is None):
        raise ReleaseError(f"{context} must provide both local-time bounds")
    _local_time(start, f"{context}.fromLocal")
    _local_time(end, f"{context}.toLocal")


def _validate_transport_rule(value: Any, context: str) -> None:
    rule = _mapping(value, context)
    rule_type = rule.get("type")
    _optional_text(rule.get("label"), f"{context}.label", maximum_bytes=256)

    conditions = _list(
        rule.get("conditions") or [],
        f"{context}.conditions",
        maximum_count=100,
    )
    condition_labels: set[str] = set()
    for index, raw_condition in enumerate(conditions):
        condition_context = f"{context}.conditions[{index}]"
        condition = _mapping(raw_condition, condition_context)
        condition_label = _required_text(
            condition.get("label"),
            f"{condition_context}.label",
            maximum_bytes=256,
        )
        if condition_label in condition_labels:
            raise ReleaseError(f"{context}.conditions has duplicate labels")
        condition_labels.add(condition_label)
        _minutes(
            condition.get("transportMinutes"),
            f"{condition_context}.transportMinutes",
        )
        _validate_time_window(condition, condition_context)
        _validate_applicability_flags(
            condition,
            (
                "appliesOnWeekdays",
                "appliesOnWeekends",
                "appliesOnPublicHolidays",
            ),
            condition_context,
        )

    if rule_type == "fixed":
        _minutes(rule.get("transportMinutes"), f"{context}.transportMinutes")
        return
    if rule_type == "range":
        minimum = _minutes(
            rule.get("minTransportMinutes"),
            f"{context}.minTransportMinutes",
        )
        maximum = _minutes(
            rule.get("maxTransportMinutes"),
            f"{context}.maxTransportMinutes",
        )
        if maximum < minimum:
            raise ReleaseError(f"{context} has an inverted transport range")
        return
    if rule_type != "timeDependent":
        raise ReleaseError(f"{context}.type is unsupported")

    rules = _list(rule.get("rules"), f"{context}.rules", maximum_count=100)
    if not rules:
        raise ReleaseError(f"{context}.rules must not be empty")
    for index, raw_time_rule in enumerate(rules):
        time_context = f"{context}.rules[{index}]"
        time_rule = _mapping(raw_time_rule, time_context)
        _optional_text(
            time_rule.get("label"),
            f"{time_context}.label",
            maximum_bytes=256,
        )
        _minutes(
            time_rule.get("transportMinutes"),
            f"{time_context}.transportMinutes",
        )
        _validate_time_window(time_rule, time_context)
        _validate_applicability_flags(
            time_rule,
            (
                "weekdaysOnly",
                "weekendsAndHolidaysOnly",
                "publicHolidaysOnly",
            ),
            time_context,
        )


def _validate_transport_document(document: Mapping[str, Any]) -> None:
    stations = _list(
        document.get("stations"),
        "transport.stations",
        maximum_count=MAX_STATIONS,
    )
    if not stations:
        raise ReleaseError("transport.stations must not be empty")

    seen_iata: set[str] = set()
    for index, raw_station in enumerate(stations):
        context = f"transport.stations[{index}]"
        station = _mapping(raw_station, context)
        iata = _required_text(
            station.get("iata"), f"{context}.iata", maximum_bytes=3
        )
        if not re.fullmatch(r"[A-Z]{3}", iata) or iata in seen_iata:
            raise ReleaseError(f"{context}.iata is invalid or duplicated")
        seen_iata.add(iata)

        icao = _required_text(
            station.get("icao"), f"{context}.icao", maximum_bytes=4
        )
        if not re.fullmatch(r"[A-Z0-9]{4}", icao):
            raise ReleaseError(f"{context}.icao is invalid")
        _required_text(
            station.get("city"), f"{context}.city", maximum_bytes=256
        )
        _required_text(
            station.get("country"), f"{context}.country", maximum_bytes=256
        )

        time_zone = _required_text(
            station.get("timeZone"),
            f"{context}.timeZone",
            maximum_bytes=128,
        )
        try:
            ZoneInfo(time_zone)
        except (ZoneInfoNotFoundError, ValueError) as error:
            raise ReleaseError(f"{context}.timeZone is invalid") from error

        for field in ("standardUtcOffset", "summerUtcOffset"):
            offset = _required_text(
                station.get(field), f"{context}.{field}", maximum_bytes=6
            )
            if not re.fullmatch(r"[+-](?:0[0-9]|1[0-4]):[0-5][0-9]", offset):
                raise ReleaseError(f"{context}.{field} is invalid")
            if offset[1:3] == "14" and offset[4:6] != "00":
                raise ReleaseError(f"{context}.{field} is invalid")

        _validate_transport_rule(station.get("defaultRule"), f"{context}.defaultRule")

        alternatives = _list(
            station.get("alternatives") or [],
            f"{context}.alternatives",
            maximum_count=50,
        )
        labels: set[str] = set()
        for alternative_index, raw_alternative in enumerate(alternatives):
            alternative_context = (
                f"{context}.alternatives[{alternative_index}]"
            )
            alternative = _mapping(raw_alternative, alternative_context)
            label = _required_text(
                alternative.get("label"),
                f"{alternative_context}.label",
                maximum_bytes=256,
            )
            if label in labels:
                raise ReleaseError(f"{context}.alternatives has duplicate labels")
            labels.add(label)
            _minutes(
                alternative.get("transportMinutes"),
                f"{alternative_context}.transportMinutes",
            )

        holidays = _list(
            station.get("holidays") or [],
            f"{context}.holidays",
            maximum_count=3_660,
        )
        holiday_dates: set[str] = set()
        for holiday_index, raw_holiday in enumerate(holidays):
            holiday_context = f"{context}.holidays[{holiday_index}]"
            holiday = _mapping(raw_holiday, holiday_context)
            holiday_date = holiday.get("date")
            _real_iso_date(holiday_date, f"{holiday_context}.date")
            if holiday_date in holiday_dates:
                raise ReleaseError(f"{context}.holidays has duplicate dates")
            holiday_dates.add(holiday_date)
            _required_text(
                holiday.get("name"),
                f"{holiday_context}.name",
                maximum_bytes=256,
            )


def _validate_hotel_document(document: Mapping[str, Any]) -> None:
    hotels = _list(
        document.get("hotels"),
        "hotel_map.hotels",
        maximum_count=MAX_HOTELS,
    )
    if not hotels:
        raise ReleaseError("hotel_map.hotels must not be empty")

    seen_iata: set[str] = set()
    for index, raw_hotel in enumerate(hotels):
        context = f"hotel_map.hotels[{index}]"
        hotel = _mapping(raw_hotel, context)
        iata = _required_text(
            hotel.get("iata"), f"{context}.iata", maximum_bytes=3
        )
        if not re.fullmatch(r"[A-Z]{3}", iata) or iata in seen_iata:
            raise ReleaseError(f"{context}.iata is invalid or duplicated")
        seen_iata.add(iata)
        icao = _required_text(
            hotel.get("icao"), f"{context}.icao", maximum_bytes=4
        )
        if not re.fullmatch(r"[A-Z0-9]{4}", icao):
            raise ReleaseError(f"{context}.icao is invalid")
        for field in ("city", "country", "name"):
            _required_text(
                hotel.get(field), f"{context}.{field}", maximum_bytes=512
            )
        for field in ("phone", "email", "fax"):
            _optional_text(
                hotel.get(field), f"{context}.{field}", maximum_bytes=512
            )


def _validate_whats_new_document(document: Mapping[str, Any]) -> None:
    visible = document.get("maxVisibleItems")
    if visible is not None and (
        not _is_integer(visible) or not 1 <= visible <= MAX_WHATS_NEW_ITEMS
    ):
        raise ReleaseError("whats_new.maxVisibleItems is invalid")

    items = _list(
        document.get("items"),
        "whats_new.items",
        maximum_count=MAX_WHATS_NEW_ITEMS,
    )
    if not items:
        raise ReleaseError("whats_new.items must not be empty")

    seen_ids: set[str] = set()
    for index, raw_item in enumerate(items):
        context = f"whats_new.items[{index}]"
        item = _mapping(raw_item, context)
        item_id = _required_text(
            item.get("id"), f"{context}.id", maximum_bytes=128
        )
        if item_id in seen_ids:
            raise ReleaseError("whats_new.items has duplicate ids")
        seen_ids.add(item_id)
        _required_text(
            item.get("title"), f"{context}.title", maximum_bytes=256
        )
        _required_text(
            item.get("detail"), f"{context}.detail", maximum_bytes=4_096
        )
        _required_text(
            item.get("documentRevision"),
            f"{context}.documentRevision",
            maximum_bytes=128,
        )
        if item.get("priority") not in {"high", "medium", "low"}:
            raise ReleaseError(f"{context}.priority is invalid")
        if item.get("category") not in {
            "transport",
            "hotel",
            "document",
            "app",
        }:
            raise ReleaseError(f"{context}.category is invalid")


def _validate_document_structure(
    definition: DatasetDefinition,
    document: Mapping[str, Any],
) -> None:
    if definition.key == "transport_rules":
        _validate_transport_document(document)
    elif definition.key == "hotel_map":
        _validate_hotel_document(document)
    elif definition.key == "whats_new":
        _validate_whats_new_document(document)
    else:
        raise ReleaseError(f"unsupported dataset {definition.key!r}")


def prepare_release(
    data_dir: Path = DEFAULT_DATA_DIR,
    generation: int = 1,
    minimum_app_version: str = MINIMUM_APP_VERSION,
) -> PreparedRelease:
    if (
        not _is_integer(generation)
        or not 1 <= generation <= MAX_GENERATION
    ):
        raise ReleaseError("generation must be positive")
    if (
        not isinstance(minimum_app_version, str)
        or len(minimum_app_version.encode("utf-8")) > 32
        or not re.fullmatch(
            r"[0-9]{1,9}\.[0-9]{1,9}(?:\.[0-9]{1,9})?",
            minimum_app_version,
        )
    ):
        raise ReleaseError("minimum app version is invalid")

    descriptors: list[dict[str, Any]] = []
    payloads: dict[str, bytes] = {}

    for definition in DATASETS:
        document, data = _load_document(data_dir / definition.filename)
        _validate_document_structure(definition, document)
        digest = hashlib.sha256(data).hexdigest()
        descriptor = {
            "key": definition.key,
            "schemaVersion": _schema_version_for(definition, document),
            "source": _source_for(definition, document),
            "objectPath": f"{definition.key}/{digest}.json",
            "sha256": digest,
            "byteCount": len(data),
        }
        descriptors.append(descriptor)
        payloads[definition.key] = data

    return PreparedRelease(
        manifest={
            "contractVersion": CONTRACT_VERSION,
            "generation": generation,
            "minimumAppVersion": minimum_app_version,
            "datasets": descriptors,
        },
        payloads=payloads,
    )


def canonical_manifest(release: PreparedRelease) -> bytes:
    return json.dumps(
        release.manifest,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def validate_supabase_url(value: str) -> tuple[str, str]:
    parsed = urllib.parse.urlparse(value)
    if (
        parsed.scheme != "https"
        or parsed.username
        or parsed.password
        or parsed.port is not None
        or parsed.path not in ("", "/")
        or parsed.params
        or parsed.query
        or parsed.fragment
        or not parsed.hostname
        or not parsed.hostname.endswith(".supabase.co")
    ):
        raise ReleaseError("Supabase URL must be an exact https://<ref>.supabase.co URL")

    project_ref = parsed.hostname.removesuffix(".supabase.co")
    if not re.fullmatch(r"[a-z0-9]{8,40}", project_ref):
        raise ReleaseError("Supabase project reference is invalid")

    return f"https://{parsed.hostname}", project_ref


class SupabasePublisher:
    def __init__(
        self,
        base_url: str,
        secret_key: str,
        opener: Callable[..., Any] = urllib.request.urlopen,
    ) -> None:
        self.base_url, self.project_ref = validate_supabase_url(base_url)
        if len(secret_key.strip()) < 20:
            raise ReleaseError("Supabase secret key is missing or invalid")
        self._secret_key = secret_key.strip()
        self._opener = opener

    def _request(
        self,
        method: str,
        path: str,
        body: bytes | None = None,
        extra_headers: Mapping[str, str] | None = None,
    ) -> bytes:
        headers = {
            "Authorization": f"Bearer {self._secret_key}",
            "apikey": self._secret_key,
            "Accept": "application/json",
        }
        if extra_headers:
            headers.update(extra_headers)

        request = urllib.request.Request(
            f"{self.base_url}{path}",
            data=body,
            headers=headers,
            method=method,
        )
        try:
            with self._opener(request, timeout=20) as response:
                status = getattr(response, "status", 200)
                payload = response.read(MAX_RESPONSE_BYTES + 1)
        except urllib.error.HTTPError as error:
            detail = error.read(501).decode("utf-8", errors="replace")[:500]
            raise ReleaseError(
                f"Supabase request failed with HTTP {error.code}: {detail}"
            ) from error
        except urllib.error.URLError as error:
            raise ReleaseError(f"Supabase request failed: {error.reason}") from error

        if not 200 <= status <= 299:
            raise ReleaseError(f"Supabase request failed with HTTP {status}")
        if len(payload) > MAX_RESPONSE_BYTES:
            raise ReleaseError("Supabase response exceeded the safe size limit")
        return payload

    def next_generation(self) -> int:
        query = "?select=generation&order=generation.desc&limit=1"
        payload = self._request(
            "GET", f"/rest/v1/wai_operational_releases{query}"
        )
        try:
            rows = json.loads(payload)
        except json.JSONDecodeError as error:
            raise ReleaseError("Supabase returned invalid release metadata") from error
        if not isinstance(rows, list) or len(rows) > 1:
            raise ReleaseError("Supabase returned ambiguous release metadata")
        if not rows:
            return 1
        generation = rows[0].get("generation") if isinstance(rows[0], dict) else None
        if (
            not _is_integer(generation)
            or not 1 <= generation < MAX_GENERATION
        ):
            raise ReleaseError("Supabase returned an invalid generation")
        return generation + 1

    def upload_payload(self, descriptor: Mapping[str, Any], data: bytes) -> None:
        path = descriptor.get("objectPath")
        digest = descriptor.get("sha256")
        if not isinstance(path, str) or not isinstance(digest, str):
            raise ReleaseError("dataset descriptor is incomplete")
        key = descriptor.get("key")
        if (
            not isinstance(key, str)
            or not SHA256_PATTERN.fullmatch(digest)
            or path != f"{key}/{digest}.json"
        ):
            raise ReleaseError("dataset descriptor path or digest is invalid")
        if hashlib.sha256(data).hexdigest() != digest:
            raise ReleaseError("dataset changed after release preparation")

        encoded_path = urllib.parse.quote(path, safe="/")
        self._request(
            "POST",
            f"/storage/v1/object/{BUCKET}/{encoded_path}",
            body=data,
            extra_headers={
                "Content-Type": "application/json",
                "x-upsert": "true",
            },
        )

    def activate_release(self, release: PreparedRelease) -> int:
        body = json.dumps(
            {
                "requested_generation": release.manifest["generation"],
                "requested_minimum_app_version": release.manifest[
                    "minimumAppVersion"
                ],
                "requested_datasets": release.manifest["datasets"],
            },
            separators=(",", ":"),
        ).encode("utf-8")
        payload = self._request(
            "POST",
            "/rest/v1/rpc/wai_publish_operational_release",
            body=body,
            extra_headers={"Content-Type": "application/json"},
        )
        try:
            release_id = json.loads(payload)
        except json.JSONDecodeError as error:
            raise ReleaseError("Supabase returned an invalid release id") from error
        if not _is_integer(release_id) or release_id <= 0:
            raise ReleaseError("Supabase returned an invalid release id")
        return release_id

    def publish(self, data_dir: Path) -> tuple[PreparedRelease, int]:
        release = prepare_release(data_dir)
        release = PreparedRelease(
            manifest={
                **release.manifest,
                "generation": self.next_generation(),
            },
            payloads=release.payloads,
        )
        descriptors = {
            descriptor["key"]: descriptor
            for descriptor in release.manifest["datasets"]
        }
        for definition in DATASETS:
            self.upload_payload(
                descriptors[definition.key], release.payloads[definition.key]
            )
        return release, self.activate_release(release)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-dir", type=Path, default=DEFAULT_DATA_DIR)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument(
        "--confirm-project-ref",
        help="Required with --apply and must exactly match the Supabase project ref.",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if not args.apply:
            release = prepare_release(args.data_dir)
            print(canonical_manifest(release).decode("utf-8"))
            print("Dry run only; no network request was made.", file=sys.stderr)
            return 0

        raw_url = os.environ.get("WAI_SUPABASE_URL", "")
        secret_key = os.environ.get("WAI_SUPABASE_SECRET_KEY", "")
        publisher = SupabasePublisher(raw_url, secret_key)
        if not args.confirm_project_ref:
            raise ReleaseError("--confirm-project-ref is required with --apply")
        if args.confirm_project_ref != publisher.project_ref:
            raise ReleaseError("confirmed project ref does not match Supabase URL")

        release, release_id = publisher.publish(args.data_dir)
        print(
            json.dumps(
                {
                    "releaseId": release_id,
                    "generation": release.manifest["generation"],
                    "projectRef": publisher.project_ref,
                },
                sort_keys=True,
            )
        )
        return 0
    except ReleaseError as error:
        print(f"Operational release failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
