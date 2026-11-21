-- WIN ZONE — 0023: app 0.5.1 starts recording even when notifications were refused, reads joined scores (0-0),
-- and sends text samples during play so the reading can be tuned
update public.game_profiles set profile = profile || '{"min_app": "0.5.1"}'::jsonb;
