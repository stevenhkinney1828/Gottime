-- connection_invites: a short-lived, single-use invitation a user creates and shares
-- out-of-band (link or pairing code). This is a discovery/invitation mechanism, not an
-- authentication mechanism — see 0006_rls_policies.sql for how redemption stays safe under
-- Row Level Security without allowing invite enumeration.

create table public.connection_invites (
    id uuid primary key default gen_random_uuid(),
    creator_id uuid not null references public.profiles (id) on delete cascade,
    invite_code text not null unique,
    status text not null default 'pending'
        check (status in ('pending', 'redeemed', 'expired', 'revoked')),
    expires_at timestamptz,
    redeemed_by uuid references public.profiles (id) on delete set null,
    redeemed_at timestamptz,
    created_at timestamptz not null default now()
);

create index connection_invites_creator_id_idx on public.connection_invites (creator_id);
