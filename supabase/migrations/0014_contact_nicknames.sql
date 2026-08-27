-- Owner's own request: a private, per-viewer label for a connection, independent of whatever
-- that person calls themselves (self-reported profiles.first_name is entirely unrestricted and
-- editable any time -- someone really could rename themselves "Mom" as a prank). Keyed by
-- (owner_user_id, target_user_id) rather than connection_id: a nickname is conceptually "what I
-- call this person," not tied to one specific connection instance, so it survives a
-- disconnect/reconnect cycle -- and every real call site (an incoming push, a call session, a
-- history entry) already has the other person's raw user id on hand, never a connection_id, so
-- this key matches how it's actually looked up everywhere. connections_active_pair_unique (see
-- 0003_connections.sql) already guarantees at most one active connection per pair, so this loses
-- nothing relationally versus keying by connection_id. See DECISIONS.md.

create table public.contact_nicknames (
    owner_user_id uuid not null references public.profiles (id) on delete cascade,
    target_user_id uuid not null references public.profiles (id) on delete cascade,
    nickname text not null check (char_length(nickname) between 1 and 50),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    primary key (owner_user_id, target_user_id),
    constraint contact_nicknames_distinct_users check (owner_user_id <> target_user_id)
);

alter table public.contact_nicknames enable row level security;

-- Read/write only your own nicknames -- never another user's private labels for their own
-- connections, which is not something anyone else has any legitimate reason to see.

create policy contact_nicknames_select_own
    on public.contact_nicknames for select
    to authenticated
    using (owner_user_id = auth.uid());

-- Setting a nickname requires an active connection to that person -- prevents attaching a
-- private label to an arbitrary user id that isn't actually a connection (a data-hygiene guard,
-- not a security-critical one: nicknames are never visible to anyone but their owner regardless).
create policy contact_nicknames_insert_own
    on public.contact_nicknames for insert
    to authenticated
    with check (
        owner_user_id = auth.uid()
        and exists (
            select 1 from public.connections c
            where c.status = 'active'
              and ((c.user_a_id = auth.uid() and c.user_b_id = target_user_id)
                or (c.user_b_id = auth.uid() and c.user_a_id = target_user_id))
        )
    );

create policy contact_nicknames_update_own
    on public.contact_nicknames for update
    to authenticated
    using (owner_user_id = auth.uid())
    with check (owner_user_id = auth.uid());

-- Clearing a nickname (reverting to the other person's own self-reported name) deletes the row
-- rather than setting it to some sentinel value -- absence of a row is the "no override" state.
create policy contact_nicknames_delete_own
    on public.contact_nicknames for delete
    to authenticated
    using (owner_user_id = auth.uid());

grant select, insert, update, delete on public.contact_nicknames to authenticated;
