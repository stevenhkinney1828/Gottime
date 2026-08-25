-- Build 15's real retest (recipient = wife, a second, different person from build 14's
-- recipient = brother) reproduced the exact same "recipient stuck on Calling..." symptom, but
-- last_call_event_status came back completely null -- not one of applyAndEmit's four outcomes
-- ever fired, even though her push_registration_status/last_incoming_push_status both show
-- fresh, successful writes seconds before the call (ruling out an auth/session problem on her
-- device). That means the gap is earlier than applyAndEmit -- somewhere in answer()/decline()
-- itself, most likely whether pendingInviteMatching finds the invite at all (a real, previously
-- floated-then-provisionally-discarded theory: a UUID mismatch between Twilio's own
-- CallInvite.uuid and this app's call_uuid). This adds two more values to the same
-- last_call_event_status column (one continuous timeline, not a new column set) so the very
-- top of answer()/decline() can report whether the invite was actually found before anything
-- else happens. See DECISIONS.md.

alter table public.profiles drop constraint profiles_last_call_event_status_check;
alter table public.profiles add constraint profiles_last_call_event_status_check
    check (last_call_event_status in (
        'no_active_session', 'uuid_mismatch', 'invalid_transition', 'applied',
        'invite_not_pending', 'invite_matched'
    ));
