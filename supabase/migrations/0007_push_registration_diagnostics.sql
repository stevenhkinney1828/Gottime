-- Two independent, guessed fixes for "real calls end in no-answer" have already gone into
-- builds (PushKitAdapter itself, then the VoIP Services Certificate/Twilio Push Credential
-- wiring) and both real-device retests still failed identically, with zero errors anywhere in
-- Twilio's own Alerts/per-call Notifications -- meaning the failure is most likely upstream of
-- Twilio ever seeing an attempt at all. The one real blind spot: PushKitAdapter's own
-- `TwilioVoiceSDK.register` call result is discarded with `try?` (see DECISIONS.md), so a real
-- registration failure -- or PushKit never handing out a token in the first place -- has been
-- completely invisible. These columns close that loop remotely, without needing device console
-- access this project has never had (no local Mac/Xcode).

alter table public.profiles
    add column push_registration_status text
        check (push_registration_status in ('requested', 'registered', 'failed')),
    add column push_registration_detail text,
    add column push_registration_updated_at timestamptz;

comment on column public.profiles.push_registration_status is
    'Set directly by the client (already covered by the existing profiles_update_self policy '
    '-- no new RLS needed). "requested": PushKit registry created, waiting on a device token. '
    '"registered": TwilioVoiceSDK.register succeeded. "failed": it threw -- see detail.';
