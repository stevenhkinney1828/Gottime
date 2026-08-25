-- Build 14 fixed the caller side for real (confirmed: a real countdown started on a real
-- device, for the first time all project) but the recipient's own screen still never left its
-- spinner despite Twilio genuinely bridging the call (the caller's countdown proves the
-- recipient's invite.accept() was reached and succeeded at the SDK/Twilio level). That means
-- the remaining gap is specifically in how the recipient's own device processes its *own*
-- CallDelegate events afterward -- exactly the kind of "looks fine, does nothing" failure this
-- session's other diagnostics were built to catch, just one layer deeper (inside
-- TwilioVoiceAdapter.applyAndEmit, the single choke point every CallDelegate callback funnels
-- through on BOTH the caller's and recipient's device). See DECISIONS.md.

alter table public.profiles
    add column last_call_event_status text
        check (last_call_event_status in (
            'no_active_session', 'uuid_mismatch', 'invalid_transition', 'applied'
        )),
    add column last_call_event_detail text,
    add column last_call_event_updated_at timestamptz;

comment on column public.profiles.last_call_event_status is
    'Set directly by the client (profiles_update_self policy already covers this), from inside '
    'TwilioVoiceAdapter.applyAndEmit -- the single place every CallDelegate callback '
    '(callDidStartRinging/callDidConnect/callDidFailToConnect/callDidDisconnect) funnels '
    'through on both the caller and recipient device. "no_active_session": activeSession was '
    'nil when the callback fired. "uuid_mismatch": activeSession existed but its callUUID '
    'didn''t match the Call/CallInvite the event was for. "invalid_transition": '
    'CallStateMachine.apply rejected the attempted status change. "applied": it worked -- the '
    'detail column names the attempted status either way.';
