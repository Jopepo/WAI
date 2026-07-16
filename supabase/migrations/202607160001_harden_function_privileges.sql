-- Supabase may add explicit API-role grants when functions are created.
-- Remove them from trigger-only helpers and keep the approval predicate scoped.
revoke all on function public.wai_create_profile()
from public, anon, authenticated, service_role;

revoke all on function public.wai_set_profile_status_timestamps()
from public, anon, authenticated, service_role;

revoke all on function public.wai_is_approved()
from public, anon, authenticated, service_role;

grant execute on function public.wai_is_approved()
to authenticated, service_role;
