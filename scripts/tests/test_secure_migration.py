import re
import unittest
from pathlib import Path


MIGRATION = (
    Path(__file__).resolve().parents[2]
    / "supabase"
    / "migrations"
    / "202607150001_secure_operational_data.sql"
)
HARDENING_MIGRATION = (
    Path(__file__).resolve().parents[2]
    / "supabase"
    / "migrations"
    / "202607160001_harden_function_privileges.sql"
)


class SecureOperationalDataMigrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sql = MIGRATION.read_text(encoding="utf-8").lower()
        cls.hardening_sql = HARDENING_MIGRATION.read_text(
            encoding="utf-8"
        ).lower()

    def test_authenticated_users_have_read_only_table_grants(self):
        self.assertIn(
            "revoke all on table public.wai_profiles from anon, authenticated;",
            self.sql,
        )
        self.assertIn(
            "grant select on table public.wai_profiles to authenticated;",
            self.sql,
        )
        self.assertIn(
            "revoke all on table public.wai_operational_releases "
            "from anon, authenticated;",
            self.sql,
        )
        self.assertIn(
            "grant select on table public.wai_operational_releases "
            "to authenticated;",
            self.sql,
        )
        self.assertNotRegex(
            self.sql,
            r"grant\s+(insert|update|delete|all).*to\s+authenticated",
        )

    def test_profile_and_release_policies_are_owner_and_approval_scoped(self):
        self.assertIn("using (id = (select auth.uid()))", self.sql)
        self.assertIn(
            "using (active and public.wai_is_approved())",
            self.sql,
        )

    def test_publish_rpc_is_service_role_only(self):
        signature = (
            "public.wai_publish_operational_release(bigint, text, jsonb)"
        )
        self.assertIn(
            f"revoke all on function {signature}\n"
            "from public, anon, authenticated;",
            self.sql,
        )
        self.assertIn(
            f"grant execute on function {signature}\n"
            "to service_role;",
            self.sql,
        )

    def test_api_roles_cannot_execute_trigger_helpers(self):
        for signature in (
            "public.wai_create_profile()",
            "public.wai_set_profile_status_timestamps()",
        ):
            self.assertIn(
                f"revoke all on function {signature}\n"
                "from public, anon, authenticated, service_role;",
                self.hardening_sql,
            )

    def test_approval_predicate_is_not_executable_by_anon(self):
        signature = "public.wai_is_approved()"
        self.assertIn(
            f"revoke all on function {signature}\n"
            "from public, anon, authenticated, service_role;",
            self.hardening_sql,
        )
        self.assertIn(
            f"grant execute on function {signature}\n"
            "to authenticated, service_role;",
            self.hardening_sql,
        )

    def test_bucket_is_private_and_reads_only_active_release_objects(self):
        self.assertRegex(
            self.sql,
            r"'wai-operational-data',\s*'wai-operational-data',\s*false,",
        )
        self.assertIn("and public.wai_is_approved()", self.sql)
        self.assertIn("where release.active", self.sql)
        self.assertIn(
            "dataset ->> 'objectpath' = storage.objects.name",
            self.sql,
        )

    def test_security_definer_functions_pin_their_search_path(self):
        functions = re.findall(
            r"create function\b.*?^\$\$;",
            self.sql,
            flags=re.DOTALL | re.MULTILINE,
        )
        security_definers = [
            function
            for function in functions
            if "security definer" in function
        ]
        self.assertGreaterEqual(len(security_definers), 3)
        for function in security_definers:
            self.assertIn("set search_path = ''", function)

    def test_reapproval_and_revoke_transitions_get_fresh_timestamps(self):
        self.assertGreaterEqual(
            self.sql.count(
                "if old.access_status is distinct from new.access_status then"
            ),
            2,
        )

    def test_existing_auth_users_are_backfilled(self):
        self.assertIn(
            "insert into public.wai_profiles (id)\n"
            "select id from auth.users\n"
            "on conflict (id) do nothing;",
            self.sql,
        )

    def test_release_metadata_is_bounded_in_the_database(self):
        self.assertIn(
            "pg_column_size(requested_datasets) > 65536",
            self.sql,
        )
        self.assertIn(
            "pg_column_size(datasets) <= 65536",
            self.sql,
        )
        self.assertIn(
            "octet_length(requested_minimum_app_version) not between 3 and 32",
            self.sql,
        )
        self.assertIn(
            "jsonb_typeof(item -> 'bytecount') <> 'number'",
            self.sql,
        )


if __name__ == "__main__":
    unittest.main()
