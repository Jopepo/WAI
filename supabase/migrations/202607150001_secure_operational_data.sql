create extension if not exists pgcrypto;

create type public.wai_access_status as enum (
  'pending',
  'approved',
  'revoked'
);

create table public.wai_profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  approval_code text not null unique
    default upper(encode(gen_random_bytes(6), 'hex')),
  access_status public.wai_access_status not null default 'pending',
  created_at timestamptz not null default now(),
  approved_at timestamptz,
  revoked_at timestamptz,
  constraint wai_profiles_approval_code_format
    check (approval_code ~ '^[0-9A-F]{12}$'),
  constraint wai_profiles_access_dates
    check (
      (access_status = 'pending' and approved_at is null and revoked_at is null)
      or (access_status = 'approved' and approved_at is not null and revoked_at is null)
      or (access_status = 'revoked' and revoked_at is not null)
    )
);

alter table public.wai_profiles enable row level security;

create function public.wai_create_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.wai_profiles (id) values (new.id);
  return new;
end;
$$;

create trigger wai_on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.wai_create_profile();

revoke all on function public.wai_create_profile() from public;

insert into public.wai_profiles (id)
select id from auth.users
on conflict (id) do nothing;

create function public.wai_set_profile_status_timestamps()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.access_status = 'pending' then
    new.approved_at = null;
    new.revoked_at = null;
  elsif new.access_status = 'approved' then
    if old.access_status is distinct from new.access_status then
      new.approved_at = now();
    else
      new.approved_at = coalesce(new.approved_at, now());
    end if;
    new.revoked_at = null;
  elsif new.access_status = 'revoked' then
    if old.access_status is distinct from new.access_status then
      new.revoked_at = now();
    else
      new.revoked_at = coalesce(new.revoked_at, now());
    end if;
  end if;

  return new;
end;
$$;

create trigger wai_before_profile_status_update
  before update of access_status on public.wai_profiles
  for each row execute procedure public.wai_set_profile_status_timestamps();

revoke all on function public.wai_set_profile_status_timestamps() from public;

create function public.wai_is_approved()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.wai_profiles
    where id = (select auth.uid())
      and access_status = 'approved'
  );
$$;

revoke all on function public.wai_is_approved() from public;
grant execute on function public.wai_is_approved() to authenticated, service_role;

create policy "Users can read their own WAI profile"
on public.wai_profiles
for select
to authenticated
using (id = (select auth.uid()));

revoke all on table public.wai_profiles from anon, authenticated;
grant select on table public.wai_profiles to authenticated;
grant all on table public.wai_profiles to service_role;

create table public.wai_operational_releases (
  id bigint generated always as identity primary key,
  generation bigint not null unique,
  contract_version integer not null,
  minimum_app_version text not null,
  datasets jsonb not null,
  active boolean not null default false,
  published_at timestamptz not null default now(),
  constraint wai_operational_release_contract
    check (contract_version = 1),
  constraint wai_operational_release_generation
    check (generation > 0),
  constraint wai_operational_release_app_version
    check (
      octet_length(minimum_app_version) between 3 and 32
      and minimum_app_version
        ~ '^[0-9]{1,9}\.[0-9]{1,9}(\.[0-9]{1,9})?$'
    ),
  constraint wai_operational_release_datasets_array
    check (jsonb_typeof(datasets) = 'array' and jsonb_array_length(datasets) = 3),
  constraint wai_operational_release_datasets_size
    check (pg_column_size(datasets) <= 65536)
);

create unique index wai_one_active_operational_release
on public.wai_operational_releases (active)
where active;

alter table public.wai_operational_releases enable row level security;

create policy "Approved users can read the active WAI release"
on public.wai_operational_releases
for select
to authenticated
using (active and public.wai_is_approved());

revoke all on table public.wai_operational_releases from anon, authenticated;
grant select on table public.wai_operational_releases to authenticated;
grant all on table public.wai_operational_releases to service_role;

create function public.wai_publish_operational_release(
  requested_generation bigint,
  requested_minimum_app_version text,
  requested_datasets jsonb
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  release_id bigint;
  dataset_keys text[];
begin
  if requested_generation <= 0 then
    raise exception 'generation must be positive';
  end if;

  if octet_length(requested_minimum_app_version) not between 3 and 32
     or requested_minimum_app_version
       !~ '^[0-9]{1,9}\.[0-9]{1,9}(\.[0-9]{1,9})?$' then
    raise exception 'minimum app version is invalid';
  end if;

  if jsonb_typeof(requested_datasets) <> 'array'
     or jsonb_array_length(requested_datasets) <> 3
     or pg_column_size(requested_datasets) > 65536 then
    raise exception 'release must contain exactly three datasets';
  end if;

  select array_agg(item ->> 'key' order by item ->> 'key')
  into dataset_keys
  from jsonb_array_elements(requested_datasets) as item;

  if dataset_keys is distinct from array['hotel_map', 'transport_rules', 'whats_new'] then
    raise exception 'release dataset keys are invalid';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(requested_datasets) as item
    where jsonb_typeof(item) <> 'object'
       or (item ->> 'schemaVersion') is distinct from case item ->> 'key'
            when 'hotel_map' then '1.0'
            when 'transport_rules' then '4.2'
            when 'whats_new' then '1.0'
          end
       or coalesce(item ->> 'objectPath', '') !~
          ('^' || (item ->> 'key') || '/[0-9a-f]{64}\.json$')
       or coalesce(item ->> 'sha256', '') !~ '^[0-9a-f]{64}$'
       or coalesce(item ->> 'objectPath', '') <> (
            (item ->> 'key') || '/' || (item ->> 'sha256') || '.json'
          )
       or jsonb_typeof(item -> 'byteCount') <> 'number'
       or case
            when coalesce(item ->> 'byteCount', '') ~ '^[0-9]{1,7}$'
              then (item ->> 'byteCount')::bigint not between 1 and 1048576
            else true
          end
       or jsonb_typeof(item -> 'source') <> 'object'
       or octet_length(coalesce(item #>> '{source,document}', ''))
          not between 1 and 512
       or octet_length(coalesce(item #>> '{source,revision}', ''))
          not between 1 and 512
       or coalesce(item #>> '{source,date}', '') !~ '^\d{4}-\d{2}-\d{2}$'
  ) then
    raise exception 'release dataset descriptor is invalid';
  end if;

  lock table public.wai_operational_releases in exclusive mode;

  if exists (
    select 1
    from public.wai_operational_releases
    where generation >= requested_generation
  ) then
    raise exception 'generation must be greater than every existing release';
  end if;

  update public.wai_operational_releases set active = false where active;

  insert into public.wai_operational_releases (
    generation,
    contract_version,
    minimum_app_version,
    datasets,
    active
  ) values (
    requested_generation,
    1,
    requested_minimum_app_version,
    requested_datasets,
    true
  ) returning id into release_id;

  return release_id;
end;
$$;

revoke all on function public.wai_publish_operational_release(bigint, text, jsonb)
from public, anon, authenticated;
grant execute on function public.wai_publish_operational_release(bigint, text, jsonb)
to service_role;

insert into storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
) values (
  'wai-operational-data',
  'wai-operational-data',
  false,
  1048576,
  array['application/json']
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create policy "Approved users can download WAI operational data"
on storage.objects
for select
to authenticated
using (
  bucket_id = 'wai-operational-data'
  and public.wai_is_approved()
  and exists (
    select 1
    from public.wai_operational_releases as release
    cross join lateral jsonb_array_elements(release.datasets) as dataset
    where release.active
      and dataset ->> 'objectPath' = storage.objects.name
  )
);
