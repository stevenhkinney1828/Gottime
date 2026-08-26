-- Owner's own request: "you can type in what the topic is and that pops up as well" — an
-- optional, caller-supplied line of context shown alongside name/duration on the recipient's
-- lock screen (composed into CallKitAdapter's localizedCallerName) and in History. Never
-- required, never affects any authorization decision (see request-call/logic.ts's own
-- sanitizeTopic, which normalizes blank input to null and truncates rather than rejecting an
-- otherwise-valid call over a minor field). Length capped to match that same truncation.
alter table public.call_sessions
    add column topic text;

alter table public.call_sessions
    add constraint call_sessions_topic_length check (topic is null or char_length(topic) <= 140);
