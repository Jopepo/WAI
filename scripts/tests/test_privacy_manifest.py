import plistlib
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "WAI/PrivacyInfo.xcprivacy"


class PrivacyManifestTests(unittest.TestCase):
    def test_known_collection_is_linked_for_functionality_not_tracking(self):
        manifest = self.load_manifest()
        collected = {
            item["NSPrivacyCollectedDataType"]: item
            for item in manifest["NSPrivacyCollectedDataTypes"]
        }

        self.assertEqual(
            set(collected),
            {
                "NSPrivacyCollectedDataTypeName",
                "NSPrivacyCollectedDataTypeEmailAddress",
                "NSPrivacyCollectedDataTypeUserID",
            },
        )
        for item in collected.values():
            self.assertIs(item["NSPrivacyCollectedDataTypeLinked"], True)
            self.assertIs(item["NSPrivacyCollectedDataTypeTracking"], False)
            self.assertEqual(
                item["NSPrivacyCollectedDataTypePurposes"],
                ["NSPrivacyCollectedDataTypePurposeAppFunctionality"],
            )

    def test_required_reason_apis_match_source_usage(self):
        manifest = self.load_manifest()
        accessed = {
            item["NSPrivacyAccessedAPIType"]:
                item["NSPrivacyAccessedAPITypeReasons"]
            for item in manifest["NSPrivacyAccessedAPITypes"]
        }

        self.assertEqual(
            accessed,
            {
                "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
                "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"],
            },
        )

    def test_tracking_is_disabled(self):
        manifest = self.load_manifest()

        self.assertIs(manifest["NSPrivacyTracking"], False)
        self.assertEqual(manifest["NSPrivacyTrackingDomains"], [])

    def load_manifest(self):
        with MANIFEST.open("rb") as handle:
            return plistlib.load(handle)


if __name__ == "__main__":
    unittest.main()
