-- WIN ZONE — 0018: the app asks players on an older version to update (0.4.0 reads kick-off, full time and short team names)
update public.game_profiles set profile = profile || '{"min_app": "0.4.0"}'::jsonb;
