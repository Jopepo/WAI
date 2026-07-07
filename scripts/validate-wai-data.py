#!/usr/bin/env python3
import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DATA_DIR = ROOT / "WAI"


def load_json(path):
    try:
        with path.open("r", encoding="utf-8") as file:
            return json.load(file)
    except Exception as error:
        raise ValueError(f"{path.name}: invalid JSON: {error}") from error


def is_hhmm(value):
    if value is None:
        return True
    if not isinstance(value, str) or len(value.split(":")) != 2:
        return False
    hour, minute = value.split(":")
    if not hour.isdigit() or not minute.isdigit():
        return False
    return 0 <= int(hour) <= 23 and 0 <= int(minute) <= 59


def is_iso_date(value):
    if not isinstance(value, str) or len(value) != 10:
        return False
    year, month, day = value.split("-")
    return len(year) == 4 and len(month) == 2 and len(day) == 2 and all(
        part.isdigit() for part in [year, month, day]
    )


def validate_transport_rule(rule, context, errors):
    rule_type = rule.get("type")
    conditions = rule.get("conditions") or []

    for condition in conditions:
        if not condition.get("label"):
            errors.append(f"{context}: condition missing label")
        if condition.get("transportMinutes", -1) < 0:
            errors.append(f"{context}: condition has invalid transportMinutes")
        if not is_hhmm(condition.get("fromLocal")) or not is_hhmm(condition.get("toLocal")):
            errors.append(f"{context}: condition has invalid local time")

    if rule_type == "fixed":
        if rule.get("transportMinutes", -1) < 0:
            errors.append(f"{context}: fixed rule has invalid transportMinutes")
    elif rule_type == "range":
        minimum = rule.get("minTransportMinutes")
        maximum = rule.get("maxTransportMinutes")
        if not isinstance(minimum, int) or not isinstance(maximum, int) or minimum < 0 or maximum < minimum:
            errors.append(f"{context}: range rule has invalid min/max")
    elif rule_type == "timeDependent":
        rules = rule.get("rules") or []
        if not rules:
            errors.append(f"{context}: timeDependent rule has no rules")
        for index, time_rule in enumerate(rules):
            label = time_rule.get("label") or f"rule {index + 1}"
            if time_rule.get("transportMinutes", -1) < 0:
                errors.append(f"{context}/{label}: invalid transportMinutes")
            if not is_hhmm(time_rule.get("fromLocal")) or not is_hhmm(time_rule.get("toLocal")):
                errors.append(f"{context}/{label}: invalid local time")
    else:
        errors.append(f"{context}: unknown rule type {rule_type!r}")


def validate_transport(document):
    errors = []
    stations = document.get("stations") or []
    if not stations:
        errors.append("transport: stations is empty")

    seen_iata = set()
    for station in stations:
        iata = station.get("iata")
        if not isinstance(iata, str) or len(iata) != 3:
            errors.append(f"transport: invalid IATA {iata!r}")
            continue
        if iata in seen_iata:
            errors.append(f"transport: duplicate IATA {iata}")
        seen_iata.add(iata)

        if not station.get("city"):
            errors.append(f"{iata}: missing city")
        if not station.get("timeZone"):
            errors.append(f"{iata}: missing timeZone")

        validate_transport_rule(station.get("defaultRule") or {}, iata, errors)

        for holiday in station.get("holidays") or []:
            if not is_iso_date(holiday.get("date")):
                errors.append(f"{iata}: invalid holiday date {holiday.get('date')!r}")
            if not holiday.get("name"):
                errors.append(f"{iata}: holiday missing name")

    return errors, seen_iata


def validate_hotels(document, transport_iatas):
    errors = []
    warnings = []
    hotels = document.get("hotels") or []
    if not hotels:
        errors.append("hotels: hotels is empty")
    if not is_iso_date(document.get("date")):
        errors.append("hotels: invalid document date")

    seen_iata = set()
    for hotel in hotels:
        iata = hotel.get("iata")
        if not isinstance(iata, str) or len(iata) != 3:
            errors.append(f"hotels: invalid IATA {iata!r}")
            continue
        if iata in seen_iata:
            errors.append(f"hotels: duplicate IATA {iata}")
        seen_iata.add(iata)

        if iata not in transport_iatas:
            warnings.append(f"hotels: {iata} has hotel data but no transport rule")
        for key in ["icao", "city", "country", "name"]:
            if not hotel.get(key):
                errors.append(f"hotels/{iata}: missing {key}")

    return errors, warnings


def validate_whats_new(document):
    errors = []
    items = document.get("items") or []
    if not items:
        errors.append("whats_new: items is empty")

    seen_ids = set()
    for item in items:
        item_id = item.get("id")
        if not item_id:
            errors.append("whats_new: item missing id")
        elif item_id in seen_ids:
            errors.append(f"whats_new: duplicate id {item_id}")
        seen_ids.add(item_id)

        for key in ["title", "detail", "priority", "category", "documentRevision"]:
            if not item.get(key):
                errors.append(f"whats_new/{item_id or 'unknown'}: missing {key}")

    return errors


def main():
    transport = load_json(DATA_DIR / "wai_transport_rules_current.json")
    hotels = load_json(DATA_DIR / "wai_hotel_map_current.json")
    whats_new = load_json(DATA_DIR / "wai_whats_new_current.json")

    errors = []
    warnings = []
    transport_errors, transport_iatas = validate_transport(transport)
    errors.extend(transport_errors)
    hotel_errors, hotel_warnings = validate_hotels(hotels, transport_iatas)
    errors.extend(hotel_errors)
    warnings.extend(hotel_warnings)
    errors.extend(validate_whats_new(whats_new))

    if errors:
        print("WAI data validation failed:")
        for error in errors:
            print(f"- {error}")
        return 1

    print("WAI data validation passed.")
    print(f"- Transport stations: {len(transport_iatas)}")
    print(f"- Hotels: {len(hotels.get('hotels') or [])}")
    print(f"- What's New items: {len(whats_new.get('items') or [])}")
    if warnings:
        print("Warnings:")
        for warning in warnings:
            print(f"- {warning}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
