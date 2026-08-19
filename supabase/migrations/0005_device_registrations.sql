-- device_registrations: the minimum device/provider information required for VoIP push and
-- Twilio Voice SDK registration. Deliberately narrow — no device model, OS version, or other
-- fingerprinting data that isn't needed to deliver a push.

create table public.device_registrations (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references public.profiles (id) on delete cascade,
    device_token text not null,
    platform text not null default 'ios' check (platform = 'ios'),
    push_environment text not null default 'sandbox'
        check (push_environment in ('sandbox', 'production')),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (user_id, device_token)
);

create index device_registrations_user_id_idx on public.device_registrations (user_id);

create trigger device_registrations_set_updated_at
    before update on public.device_registrations
    for each row execute function public.set_updated_at();
