-- connections: an undirected relationship between two users. user_a_id/user_b_id order is
-- not meaningful (redeem_connection_invite() always stores the pair as least/greatest so
-- the "no duplicate active connections" rule below can be enforced regardless of who
-- initiated).

create table public.connections (
    id uuid primary key default gen_random_uuid(),
    user_a_id uuid not null references public.profiles (id) on delete cascade,
    user_b_id uuid not null references public.profiles (id) on delete cascade,
    status text not null default 'active' check (status in ('active', 'removed')),
    created_at timestamptz not null default now(),
    constraint connections_distinct_users check (user_a_id <> user_b_id)
);

create index connections_user_a_id_idx on public.connections (user_a_id);
create index connections_user_b_id_idx on public.connections (user_b_id);

-- Prevent duplicate *active* connections between the same pair, regardless of which side is
-- "a" vs "b". A removed connection can be re-established (a fresh active row), which is why
-- this is a partial index rather than a plain unique constraint.
create unique index connections_active_pair_unique
    on public.connections (least(user_a_id, user_b_id), greatest(user_a_id, user_b_id))
    where status = 'active';
