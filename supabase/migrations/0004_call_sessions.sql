-- call_sessions: the authoritative record of one timed call, from creation through to a
-- terminal status. requested_duration_seconds is bounded 60-3600 (1-60 whole minutes) at the
-- database layer as one of the three independent duration-enforcement layers described in
-- DECISIONS.md — the other two are the Edge Function that creates this row and
-- GotTimeCore's DurationPolicy on the client.

create table public.call_sessions (
    id uuid primary key default gen_random_uuid(),
    call_uuid uuid not null unique default gen_random_uuid(),
    caller_id uuid not null references public.profiles (id) on delete cascade,
    recipient_id uuid not null references public.profiles (id) on delete cascade,
    requested_duration_seconds integer not null
        check (requested_duration_seconds between 60 and 3600),
    initiated_at timestamptz not null default now(),
    ringing_at timestamptz,
    connected_at timestamptz,
    ended_at timestamptz,
    actual_duration_seconds integer,
    provider_call_sid text,
    status text not null default 'created' check (status in (
        'created', 'outgoing', 'ringing', 'connected', 'declined', 'missed', 'failed',
        'ended_early', 'timed_out', 'completed'
    )),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint call_sessions_distinct_participants check (caller_id <> recipient_id)
);

create index call_sessions_caller_id_idx on public.call_sessions (caller_id);
create index call_sessions_recipient_id_idx on public.call_sessions (recipient_id);
create index call_sessions_call_uuid_idx on public.call_sessions (call_uuid);

create trigger call_sessions_set_updated_at
    before update on public.call_sessions
    for each row execute function public.set_updated_at();
