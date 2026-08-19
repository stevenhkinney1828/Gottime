-- Row Level Security for every table. Principle throughout: the client (using the anon/
-- authenticated Supabase key) can only ever read its own data or data about an active
-- connection; every privileged write (creating/authorizing a call, registering a device,
-- redeeming an invite against someone else's row) happens either through a SECURITY DEFINER
-- function scoped to exactly one safe operation, or through an Edge Function using the
-- service role, which bypasses RLS entirely and is trusted to enforce the real rules itself
-- (spec section 13: never trust arbitrary client values for privileged operations).

alter table public.profiles enable row level security;
alter table public.connection_invites enable row level security;
alter table public.connections enable row level security;
alter table public.call_sessions enable row level security;
alter table public.device_registrations enable row level security;

-- --- profiles ---------------------------------------------------------------------------
-- Read your own profile, or the profile of anyone you have an active connection with.
-- No policy permits broad enumeration of all profiles.

create policy profiles_select_self_or_connected
    on public.profiles for select
    to authenticated
    using (
        id = auth.uid()
        or exists (
            select 1 from public.connections c
            where c.status = 'active'
              and ((c.user_a_id = auth.uid() and c.user_b_id = profiles.id)
                or (c.user_b_id = auth.uid() and c.user_a_id = profiles.id))
        )
    );

create policy profiles_update_self
    on public.profiles for update
    to authenticated
    using (id = auth.uid())
    with check (id = auth.uid());

-- No INSERT/DELETE policy: rows are created by the auth.users trigger (0001) and removed via
-- cascade from account deletion, never directly by a client.

-- --- connection_invites ------------------------------------------------------------------
-- Manage only invites you created. A plain SELECT policy permissive enough to let a
-- *different* user look up an invite by code would also let them enumerate every invite that
-- happens to match, so redemption by another user goes exclusively through
-- redeem_connection_invite() below instead of a table policy.

create policy connection_invites_select_own
    on public.connection_invites for select
    to authenticated
    using (creator_id = auth.uid());

create policy connection_invites_insert_own
    on public.connection_invites for insert
    to authenticated
    with check (creator_id = auth.uid());

create policy connection_invites_update_own
    on public.connection_invites for update
    to authenticated
    using (creator_id = auth.uid())
    with check (creator_id = auth.uid());

-- --- connections ---------------------------------------------------------------------------
-- See and update (e.g. mark 'removed') only connections you're part of. No client INSERT —
-- rows are created exclusively by redeem_connection_invite() below.

create policy connections_select_participant
    on public.connections for select
    to authenticated
    using (auth.uid() = user_a_id or auth.uid() = user_b_id);

create policy connections_update_participant
    on public.connections for update
    to authenticated
    using (auth.uid() = user_a_id or auth.uid() = user_b_id)
    with check (auth.uid() = user_a_id or auth.uid() = user_b_id);

-- --- call_sessions ---------------------------------------------------------------------------
-- Read only calls you took part in. No client INSERT/UPDATE at all: creating and authorizing
-- a call means validating the caller, the recipient, that a live connection exists between
-- them, and the requested duration — all of which happens in the request-call Edge Function
-- using the service role, never trusting client-supplied values for any of it.

create policy call_sessions_select_participant
    on public.call_sessions for select
    to authenticated
    using (auth.uid() = caller_id or auth.uid() = recipient_id);

-- --- device_registrations ---------------------------------------------------------------------
-- Read your own registrations only. No client INSERT/UPDATE — registration is handled by the
-- register-device Edge Function (service role), which also validates token format and
-- resolves the push environment.

create policy device_registrations_select_own
    on public.device_registrations for select
    to authenticated
    using (auth.uid() = user_id);

-- --- baseline grants -----------------------------------------------------------------------
-- RLS policies above are the real restriction; these grants just allow the authenticated
-- role to attempt the statements the policies then filter row-by-row.

grant usage on schema public to authenticated, service_role;
grant select, update on public.profiles to authenticated;
grant select, insert, update on public.connection_invites to authenticated;
grant select, update on public.connections to authenticated;
grant select on public.call_sessions to authenticated;
grant select on public.device_registrations to authenticated;
grant all on all tables in schema public to service_role;
grant execute on all functions in schema public to service_role;

-- --- invite redemption ---------------------------------------------------------------------
-- The one place a user needs to act on a row they didn't create. Runs as SECURITY DEFINER so
-- it can look up an invite by its exact code and create the resulting connection atomically,
-- without ever needing a table-level SELECT policy that would let redeemers enumerate other
-- users' invites.

create or replace function public.redeem_connection_invite(p_invite_code text)
returns public.connections
language plpgsql
security definer
set search_path = public
as $$
declare
    v_invite public.connection_invites;
    v_connection public.connections;
    v_user_a uuid;
    v_user_b uuid;
begin
    if auth.uid() is null then
        raise exception 'Not authenticated';
    end if;

    select * into v_invite
    from public.connection_invites
    where invite_code = p_invite_code
    for update;

    if not found then
        raise exception 'Invalid invite code';
    end if;

    if v_invite.status <> 'pending' then
        raise exception 'Invite is no longer available';
    end if;

    if v_invite.expires_at is not null and v_invite.expires_at < now() then
        update public.connection_invites set status = 'expired' where id = v_invite.id;
        raise exception 'Invite has expired';
    end if;

    if v_invite.creator_id = auth.uid() then
        raise exception 'Cannot redeem your own invite';
    end if;

    v_user_a := least(v_invite.creator_id, auth.uid());
    v_user_b := greatest(v_invite.creator_id, auth.uid());

    insert into public.connections (user_a_id, user_b_id, status)
    values (v_user_a, v_user_b, 'active')
    on conflict (least(user_a_id, user_b_id), greatest(user_a_id, user_b_id))
        where status = 'active'
    do nothing
    returning * into v_connection;

    if v_connection.id is null then
        raise exception 'Already connected';
    end if;

    update public.connection_invites
        set status = 'redeemed', redeemed_by = auth.uid(), redeemed_at = now()
        where id = v_invite.id;

    return v_connection;
end;
$$;

-- Postgres grants EXECUTE to PUBLIC by default on every new function; revoke that implicit
-- grant and state the intended access explicitly instead of relying on the default. (The
-- function's own `if auth.uid() is null then raise exception` check would still block
-- unauthenticated use even without this, but the grant should say what's intended, not rely
-- on a runtime check to compensate for an overly broad grant.)
revoke execute on function public.redeem_connection_invite(text) from public;
grant execute on function public.redeem_connection_invite(text) to authenticated, service_role;
