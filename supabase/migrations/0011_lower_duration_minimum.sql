-- Owner requested short preset options (15s, 30s) directly in the duration picker, alongside
-- the existing whole-minute presets. Lowers the floor from 60 to 15 seconds to allow them --
-- matches request-call/logic.ts's MIN_DURATION_SECONDS (also updated to 15) and
-- DurationPolicy.swift's new presetSeconds. Upper bound (3600s / 60 min) unchanged.

alter table public.call_sessions drop constraint call_sessions_requested_duration_seconds_check;
alter table public.call_sessions add constraint call_sessions_requested_duration_seconds_check
    check (requested_duration_seconds between 15 and 3600);
