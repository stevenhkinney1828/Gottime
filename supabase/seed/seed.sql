-- Local dev/test seed data only. Never run against a real Supabase project.
-- Three fake users: Alice and Bob are connected; Carol is not connected to anyone, and
-- exists specifically to test that RLS correctly denies her access to Alice/Bob's data.

insert into auth.users (id, email, raw_user_meta_data) values
    ('11111111-1111-1111-1111-111111111111', 'alice@example.test', '{"first_name": "Alice"}'),
    ('22222222-2222-2222-2222-222222222222', 'bob@example.test', '{"first_name": "Bob"}'),
    ('33333333-3333-3333-3333-333333333333', 'carol@example.test', '{"first_name": "Carol"}')
on conflict (id) do nothing;

-- profiles rows are created by the on_auth_user_created trigger (0001_profiles.sql) as a
-- side effect of the inserts above.

insert into public.connections (user_a_id, user_b_id, status) values
    ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 'active')
on conflict do nothing;

insert into public.connection_invites (creator_id, invite_code, status) values
    ('33333333-3333-3333-3333-333333333333', 'CAROL1', 'pending')
on conflict do nothing;

insert into public.call_sessions
    (caller_id, recipient_id, requested_duration_seconds, status, connected_at, ended_at, actual_duration_seconds)
values
    ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
     600, 'completed', now() - interval '1 hour', now() - interval '50 minutes', 600)
on conflict do nothing;
