-- WIN ZONE — 0022: app 0.5.0 contains the whole site (tournaments, live scores, my matches, rankings, admin)
update public.game_profiles set profile = profile || '{"min_app": "0.5.0"}'::jsonb;
