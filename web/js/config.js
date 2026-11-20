// Public configuration. The anon key is designed to be public (access is enforced by database rules).
// Never put the service_role / secret key here. Leave SUPABASE_URL empty to run in sample-data mode.
export const CONFIG = {
  SUPABASE_URL: "https://jfniylmbogodgozcczln.supabase.co",
  SUPABASE_ANON_KEY: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Impmbml5bG1ib2dvZGdvemNjemxuIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTAzOTUyMDUsImV4cCI6MjEwNTk3MTIwNX0.Y1nQdsJZG8SJL4-BziGu7A13_YDnR-Ud2vX-wB5bro4",
  CONTACT_EMAIL: "",
  APK_URL: "",
  APP_SCHEME: "winzone",
  VAPID_PUBLIC_KEY: "BP3MK9kZ7jmxv6mp2BGL1N2T72UQ2c3aeQfHgcLVdLjFq04p01TT7RnNOlz5BQjNLu69ihWqNya_ld_x9Hyw4TI",   // public half of the push key pair (safe to publish)
  APP_PACKAGE: "app.winzone.player",   // Android package id of the WIN ZONE app (Phase 2)
};
