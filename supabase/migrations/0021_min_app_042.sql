-- WIN ZONE — 0021: app 0.4.2 records the entire screen on Android 14+, follows rotation, ignores the phone's own clock
update public.game_profiles set profile = profile || '{"min_app": "0.4.2"}'::jsonb;
