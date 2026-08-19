-- Local-only approximation of Supabase's real `auth` schema, roles, and JWT-claim functions,
-- so migrations and RLS policies can be dry-run against a plain local Postgres install with
-- no Supabase project and no Docker. Run this BEFORE the migrations in local testing:
--
--   psql "$DATABASE_URL" -f supabase/seed/auth_shim.sql
--   for f in supabase/migrations/*.sql; do psql "$DATABASE_URL" -f "$f"; done
--
-- NEVER run this against a real Supabase project — it already has a real `auth` schema, and
-- this would conflict with it. See KNOWN_LIMITATIONS.md: this is a fast approximation for
-- local iteration, not a substitute for a final verification pass against the real project.

create schema if not exists auth;

create table if not exists auth.users (
    id uuid primary key default gen_random_uuid(),
    email text,
    raw_user_meta_data jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now()
);

-- Real Supabase's auth.uid()/auth.role()/auth.jwt() read claims from the JWT that PostgREST
-- sets via `SET LOCAL request.jwt.claims` on each request. Here, tests set a couple of plain
-- session settings directly instead — see set_local_test_user() below.

create or replace function auth.uid() returns uuid
language sql stable
as $$
    select nullif(current_setting('app.current_user_id', true), '')::uuid;
$$;

create or replace function auth.role() returns text
language sql stable
as $$
    select coalesce(nullif(current_setting('app.current_role', true), ''), 'anon');
$$;

create or replace function auth.jwt() returns jsonb
language sql stable
as $$
    select coalesce(nullif(current_setting('app.current_jwt', true), ''), '{}')::jsonb;
$$;

do $$
begin
    if not exists (select 1 from pg_roles where rolname = 'anon') then
        create role anon nologin;
    end if;
    if not exists (select 1 from pg_roles where rolname = 'authenticated') then
        create role authenticated nologin;
    end if;
    if not exists (select 1 from pg_roles where rolname = 'service_role') then
        create role service_role nologin bypassrls;
    end if;
end $$;

-- Test helper: simulate "signed in as this user" for the rest of the current session.
-- Deliberately SESSION-scoped (set_config's third argument is `false`, not `true`), not
-- transaction-scoped — real PostgREST uses SET LOCAL per-request (transaction-scoped), but
-- that requires wrapping every test in an explicit BEGIN/COMMIT to survive across statements,
-- which is easy to get wrong in a plain psql script. Session scoping trades a little
-- fidelity for a lot less footgun risk in local/CI test scripts. Use plain `SET ROLE`, not
-- `SET LOCAL ROLE`, for the same reason — see usage below.
--
-- Usage in a psql session or script:
--   select set_local_test_user('11111111-1111-1111-1111-111111111111'::uuid);
--   set role authenticated;
--   select * from public.profiles;  -- now filtered by RLS as that user
--   reset role;                     -- back to superuser before the next unrelated statement
--   select clear_local_test_user();
create or replace function public.set_local_test_user(p_user_id uuid) returns void
language sql
as $$
    select set_config('app.current_user_id', p_user_id::text, false);
$$;

-- Test helper: clear simulated identity (falls back to anon/no-uid, matching a logged-out
-- request). Call `reset role;` separately first if a role was also switched.
create or replace function public.clear_local_test_user() returns void
language sql
as $$
    select set_config('app.current_user_id', '', false);
$$;
