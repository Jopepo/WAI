import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
FUNCTION = ROOT / "supabase/functions/delete-account/index.ts"
MIGRATION = ROOT / "supabase/migrations/202607150001_secure_operational_data.sql"


class AccountDeletionBoundaryTests(unittest.TestCase):
    def test_server_sequence_verifies_reauth_revokes_then_deletes(self):
        source = FUNCTION.read_text(encoding="utf-8")

        user_check = source.index("adminClient.auth.getUser")
        exchange = source.index("exchangeAppleAuthorizationCode")
        identity_match = source.index("guardAppleIdentityMatches")
        revoke = source.index("await revokeAppleToken")
        delete = source.index("adminClient.auth.admin.deleteUser")

        self.assertLess(user_check, exchange)
        self.assertLess(exchange, identity_match)
        self.assertLess(identity_match, revoke)
        self.assertLess(revoke, delete)
        self.assertIn("https://appleid.apple.com/auth/token", source)
        self.assertIn("https://appleid.apple.com/auth/revoke", source)
        self.assertIn("https://appleid.apple.com/auth/keys", source)
        self.assertIn("await verifyAppleIdentityToken", source)
        self.assertIn('header.alg !== "RS256"', source)
        self.assertIn("crypto.subtle.verify", source)

    def test_privileged_secrets_are_server_only(self):
        function_source = FUNCTION.read_text(encoding="utf-8")
        self.assertIn('Deno.env.get(name)', function_source)
        self.assertIn('"SUPABASE_SERVICE_ROLE_KEY"', function_source)
        self.assertIn('"APPLE_PRIVATE_KEY"', function_source)

        forbidden = (
            "SUPABASE_SERVICE_ROLE_KEY",
            "APPLE_PRIVATE_KEY",
            "sb_secret_",
            "-----BEGIN PRIVATE KEY-----",
        )
        for swift_file in (ROOT / "WAI").glob("*.swift"):
            source = swift_file.read_text(encoding="utf-8")
            for marker in forbidden:
                self.assertNotIn(marker, source, swift_file.name)

    def test_function_does_not_log_credentials_or_return_tokens(self):
        source = FUNCTION.read_text(encoding="utf-8")

        self.assertNotIn("console.", source)
        self.assertIn("return jsonResponse(200, { deleted: true })", source)
        self.assertNotIn("{ deleted: true,", source)

    def test_profile_is_deleted_by_auth_user_cascade(self):
        migration = MIGRATION.read_text(encoding="utf-8").lower()

        self.assertIn(
            "id uuid primary key references auth.users (id) on delete cascade",
            migration,
        )


if __name__ == "__main__":
    unittest.main()
