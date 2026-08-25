-- The latest real retest reached real progress: Twilio's own call events show "ringing" for
-- 10-11 seconds (not the instant 0-duration no-answer every earlier attempt showed), ending in
-- SIP 487 ("Request Terminated" -- consistent with the caller hitting Cancel after waiting).
-- That means Twilio genuinely found a registered route and attempted delivery. What's still
-- unknown: whether the VoIP push actually reached the recipient's device, and if so, exactly
-- which step of receiving/parsing/handling it succeeded or failed -- none of that path
-- (PushKitAdapter's `didReceiveIncomingPushWith`/`callInviteReceived`) has ever reported
-- anything, the same kind of blind spot the earlier push_registration_status columns closed for
-- the outgoing/registration side. See DECISIONS.md.

alter table public.profiles
    add column last_incoming_push_status text
        check (last_incoming_push_status in (
            'push_received', 'invite_unparseable', 'invite_parsed',
            'context_fetched', 'context_fetch_failed', 'delivered_to_coordinator'
        )),
    add column last_incoming_push_detail text,
    add column last_incoming_push_updated_at timestamptz;

comment on column public.profiles.last_incoming_push_status is
    'Set directly by the client (profiles_update_self policy already covers this -- no new RLS '
    'needed), tracing PushKitAdapter''s incoming-push handling: push_received (PushKit delegate '
    'fired) -> invite_parsed/invite_unparseable (callInviteReceived''s guard) -> '
    'context_fetched/context_fetch_failed (profile+session lookup) -> delivered_to_coordinator '
    '(TwilioVoiceAdapter told, ready to surface IncomingCallView). A push that never even '
    'reaches "push_received" means PushKit itself never got the push.';
