-- WIN ZONE — 0024: app 0.5.2 reads the real match screen (score bar "FCB 3 - 0 PLA" beside the clock, labels below it)
update public.game_profiles set profile = profile || '{"min_app": "0.5.2"}'::jsonb;
