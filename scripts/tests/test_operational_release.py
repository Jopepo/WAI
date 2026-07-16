import hashlib
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "operational_release.py"
SPEC = importlib.util.spec_from_file_location("operational_release", MODULE_PATH)
operational_release = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = operational_release
SPEC.loader.exec_module(operational_release)


class OperationalReleaseTests(unittest.TestCase):
    def write_documents(self, root: Path) -> None:
        documents = {
            "wai_transport_rules_current.json": {
                "schemaVersion": "4.2",
                "source": {
                    "document": "Transport Test",
                    "revision": "REV1",
                    "date": "2026-07-15",
                },
                "stations": [
                    {
                        "iata": "TST",
                        "icao": "TEST",
                        "city": "Test City",
                        "country": "Testland",
                        "timeZone": "UTC",
                        "standardUtcOffset": "+00:00",
                        "summerUtcOffset": "+00:00",
                        "defaultRule": {
                            "type": "fixed",
                            "transportMinutes": 30,
                        },
                        "alternatives": [],
                    }
                ],
            },
            "wai_hotel_map_current.json": {
                "document": "Hotel Test",
                "revision": "REV1",
                "date": "2026-07-15",
                "hotels": [
                    {
                        "iata": "TST",
                        "icao": "TEST",
                        "city": "Test City",
                        "country": "Testland",
                        "name": "Test Hotel",
                    }
                ],
            },
            "wai_whats_new_current.json": {
                "source": {
                    "document": "What's New Test",
                    "revision": "v3.0",
                    "date": "2026-07-15",
                },
                "maxVisibleItems": 1,
                "items": [
                    {
                        "id": "test",
                        "title": "Test update",
                        "detail": "Test detail",
                        "priority": "low",
                        "category": "app",
                        "documentRevision": "v3.0",
                    }
                ],
            },
        }
        for filename, document in documents.items():
            (root / filename).write_text(
                json.dumps(document, ensure_ascii=False), encoding="utf-8"
            )

    def test_prepares_complete_content_addressed_release(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_documents(root)

            release = operational_release.prepare_release(root, generation=7)

            self.assertEqual(release.manifest["contractVersion"], 1)
            self.assertEqual(release.manifest["generation"], 7)
            self.assertEqual(
                [item["key"] for item in release.manifest["datasets"]],
                ["hotel_map", "transport_rules", "whats_new"],
            )
            for descriptor in release.manifest["datasets"]:
                payload = release.payloads[descriptor["key"]]
                digest = hashlib.sha256(payload).hexdigest()
                self.assertEqual(descriptor["sha256"], digest)
                self.assertEqual(
                    descriptor["objectPath"],
                    f"{descriptor['key']}/{digest}.json",
                )

    def test_rejects_missing_transport_schema_version(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_documents(root)
            path = root / "wai_transport_rules_current.json"
            document = json.loads(path.read_text(encoding="utf-8"))
            document.pop("schemaVersion")
            path.write_text(json.dumps(document), encoding="utf-8")

            with self.assertRaisesRegex(
                operational_release.ReleaseError, "schema version is missing"
            ):
                operational_release.prepare_release(root)

    def test_rejects_unsupported_transport_schema_version(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_documents(root)
            path = root / "wai_transport_rules_current.json"
            document = json.loads(path.read_text(encoding="utf-8"))
            document["schemaVersion"] = "5.0"
            path.write_text(json.dumps(document), encoding="utf-8")

            with self.assertRaisesRegex(
                operational_release.ReleaseError, "unsupported schema version"
            ):
                operational_release.prepare_release(root)

    def test_rejects_invalid_source_date(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_documents(root)
            path = root / "wai_hotel_map_current.json"
            document = json.loads(path.read_text(encoding="utf-8"))
            document["date"] = "2026-02-31"
            path.write_text(json.dumps(document), encoding="utf-8")

            with self.assertRaisesRegex(
                operational_release.ReleaseError, "real ISO date"
            ):
                operational_release.prepare_release(root)

    def test_rejects_transport_minutes_that_could_overflow_the_app(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_documents(root)
            path = root / "wai_transport_rules_current.json"
            document = json.loads(path.read_text(encoding="utf-8"))
            document["stations"][0]["defaultRule"]["transportMinutes"] = (
                sys.maxsize
            )
            path.write_text(json.dumps(document), encoding="utf-8")

            with self.assertRaisesRegex(
                operational_release.ReleaseError, "between 0 and 1440"
            ):
                operational_release.prepare_release(root)

    def test_rejects_negative_whats_new_visible_count(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_documents(root)
            path = root / "wai_whats_new_current.json"
            document = json.loads(path.read_text(encoding="utf-8"))
            document["maxVisibleItems"] = -1
            path.write_text(json.dumps(document), encoding="utf-8")

            with self.assertRaisesRegex(
                operational_release.ReleaseError, "maxVisibleItems is invalid"
            ):
                operational_release.prepare_release(root)

    def test_rejects_boolean_or_out_of_range_generation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_documents(root)

            for generation in (True, operational_release.MAX_GENERATION + 1):
                with self.subTest(generation=generation):
                    with self.assertRaisesRegex(
                        operational_release.ReleaseError,
                        "generation must be positive",
                    ):
                        operational_release.prepare_release(
                            root,
                            generation=generation,
                        )

    def test_rejects_version_components_outside_backend_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_documents(root)

            with self.assertRaisesRegex(
                operational_release.ReleaseError,
                "minimum app version is invalid",
            ):
                operational_release.prepare_release(
                    root,
                    minimum_app_version="3.1234567890",
                )

    def test_rejects_incomplete_operational_records(self):
        cases = (
            ("wai_transport_rules_current.json", "stations", {"iata": "TST"}),
            ("wai_hotel_map_current.json", "hotels", {"iata": "TST"}),
            ("wai_whats_new_current.json", "items", {"id": "test"}),
        )
        for filename, collection, incomplete_record in cases:
            with self.subTest(filename=filename):
                with tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    self.write_documents(root)
                    path = root / filename
                    document = json.loads(path.read_text(encoding="utf-8"))
                    document[collection] = [incomplete_record]
                    path.write_text(json.dumps(document), encoding="utf-8")

                    with self.assertRaises(operational_release.ReleaseError):
                        operational_release.prepare_release(root)

    def test_publish_rejects_invalid_documents_before_any_network_request(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_documents(root)
            path = root / "wai_hotel_map_current.json"
            document = json.loads(path.read_text(encoding="utf-8"))
            document["hotels"] = [{"iata": "TST"}]
            path.write_text(json.dumps(document), encoding="utf-8")
            requests = []

            def opener(*args, **kwargs):
                requests.append((args, kwargs))
                raise AssertionError("network must not be reached")

            publisher = operational_release.SupabasePublisher(
                "https://waistaging1234567890.supabase.co",
                "test-secret-key-that-is-long-enough",
                opener=opener,
            )

            with self.assertRaises(operational_release.ReleaseError):
                publisher.publish(root)
            self.assertEqual(requests, [])

    def test_supabase_url_is_restricted_to_exact_host(self):
        base_url, project_ref = operational_release.validate_supabase_url(
            "https://waistaging1234567890.supabase.co"
        )
        self.assertEqual(
            base_url, "https://waistaging1234567890.supabase.co"
        )
        self.assertEqual(project_ref, "waistaging1234567890")

        unsafe_values = [
            "http://waistaging1234567890.supabase.co",
            "https://waistaging1234567890.supabase.co/other",
            "https://waistaging1234567890.supabase.co@example.com",
            "https://wai-staging.supabase.co",
            "https://short.supabase.co",
            "https://example.com",
        ]
        for value in unsafe_values:
            with self.subTest(value=value):
                with self.assertRaises(operational_release.ReleaseError):
                    operational_release.validate_supabase_url(value)

    def test_supabase_response_read_is_bounded(self):
        class OversizedResponse:
            status = 200

            def __init__(self):
                self.requested_bytes = None

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc_value, traceback):
                return False

            def read(self, maximum_bytes):
                self.requested_bytes = maximum_bytes
                return b"x" * maximum_bytes

        response = OversizedResponse()
        publisher = operational_release.SupabasePublisher(
            "https://waistaging1234567890.supabase.co",
            "test-secret-key-that-is-long-enough",
            opener=lambda *args, **kwargs: response,
        )

        with self.assertRaisesRegex(
            operational_release.ReleaseError,
            "safe size limit",
        ):
            publisher._request("GET", "/test")
        self.assertEqual(
            response.requested_bytes,
            operational_release.MAX_RESPONSE_BYTES + 1,
        )

    def test_dry_run_needs_no_credentials_and_does_not_publish(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_documents(root)
            result = operational_release.main(["--data-dir", str(root)])
            self.assertEqual(result, 0)


if __name__ == "__main__":
    unittest.main()
