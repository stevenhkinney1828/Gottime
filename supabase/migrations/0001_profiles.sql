-- profiles: one row per authenticated user, keyed to auth.users.id.
-- No public profile, bio, follower model, or username culture — first_name only, by design.

create extension if not exists pgcrypto;

create table public.profiles (
    id uuid primary key references auth.users (id) on delete cascade,
    first_name text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

comment on column public.profiles.first_name is
    'Nullable because Sign in with Apple does not always supply a name (and the user can '
    'decline to share it); the app onboarding flow requires it before allowing connections '
    'or calls.';

create or replace function public.set_updated_at() returns trigger
language plpgsql as $$
begin
    new.updated_at = now();
    return new;
end;
$$;

create trigger profiles_set_updated_at
    before update on public.profiles
    for each row execute function public.set_updated_at();

-- Auto-create a profile the moment a new auth.users row appears, so the client is never
-- granted direct INSERT access to profiles (see 0006_rls_policies.sql).
create or replace function public.handle_new_user() returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    insert into public.profiles (id, first_name)
    values (new.id, new.raw_user_meta_data ->> 'first_name');
    return new;
end;
$$;

create trigger on_auth_user_created
    after insert on auth.users
    for each row execute function public.handle_new_user();
