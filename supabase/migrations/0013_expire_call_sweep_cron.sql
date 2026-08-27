-- Phase 6's third and final duration-enforcement layer: a periodic backstop for any
-- call_sessions row that never reaches a terminal status on its own. Real evidence this is a
-- genuine, not hypothetical, gap: direct queries during real-device testing found rows stuck
-- in "ringing"/"created"/"outgoing" for hours, sometimes over a day, because the only thing
-- that ever drove a resolution was the caller's own device -- which a killed app, a dropped
-- network, or abandoned testing can silently prevent from ever reporting back. See DECISIONS.md.
--
-- Schedules a call to the already-deployed expire-call-sweep Edge Function every minute via
-- pg_cron + pg_net, authenticated with a service-role JWT. That credential is NOT stored in
-- this file -- it's provisioned once, directly against the live project, via
-- vault.create_secret(), the same way every other real secret in this project (Twilio, Apple)
-- has always been handled. This migration only references it by name.

create extension if not exists pg_cron;
create extension if not exists pg_net;

select
  cron.schedule(
    'expire-call-sweep',
    '* * * * *',
    $$
    select net.http_post(
      url := 'https://wraowtlpekpmpekkcquq.supabase.co/functions/v1/expire-call-sweep',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || (
          select decrypted_secret from vault.decrypted_secrets where name = 'expire_call_sweep_service_role_key'
        )
      ),
      body := '{}'::jsonb
    );
    $$
  );
