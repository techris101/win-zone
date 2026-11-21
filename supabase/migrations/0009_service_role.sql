-- WIN ZONE — 0009 server role access
-- Supabase's trusted server role (used only by server functions such as send-push; its key never reaches a browser)
-- must be able to read and write our tables. Standard projects grant this by default; this project did not, so it is
-- granted explicitly here, now and for anything created later.
grant usage on schema public to service_role;
grant all on all tables in schema public to service_role;
grant all on all sequences in schema public to service_role;
grant execute on all functions in schema public to service_role;
alter default privileges in schema public grant all on tables to service_role;
alter default privileges in schema public grant all on sequences to service_role;
alter default privileges in schema public grant execute on functions to service_role;
