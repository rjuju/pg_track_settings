CREATE EXTENSION pg_track_settings;
-- test main config history
SELECT COUNT(*) FROM public.pg_track_settings_history;
SET work_mem = '10MB';
SELECT * FROM public.pg_track_settings_snapshot();
SELECT pg_catalog.pg_sleep(1);
SET work_mem = '5MB';
SELECT * FROM public.pg_track_settings_snapshot();
SELECT name, setting_exists, setting, setting_pretty FROM public.pg_track_settings_log('work_mem') ORDER BY ts ASC;
SELECT name, from_setting, from_exists, to_setting, to_exists, from_setting_pretty, to_setting_pretty FROM public.pg_track_settings_diff(now() - interval '500 ms', now());
-- test pg_db_role_settings
ALTER DATABASE postgres SET work_mem = '1MB';
SELECT * FROM public.pg_track_settings_snapshot();
ALTER ROLE postgres SET work_mem = '2MB';
SELECT * FROM public.pg_track_settings_snapshot();
ALTER ROLE postgres IN DATABASE postgres SET work_mem = '3MB';
SELECT * FROM public.pg_track_settings_snapshot();
SELECT * FROM public.pg_track_settings_snapshot();
SELECT COALESCE(datname, '-') AS datname, setrole::regrole, name, setting_exists, setting FROM public.pg_track_db_role_settings_log('work_mem') s LEFT JOIN pg_database d ON d.oid = s.setdatabase ORDER BY ts ASC;
SELECT COALESCE(datname, '-') AS datname, setrole::regrole, name, from_setting, from_exists, to_setting, to_exists FROM public.pg_track_db_role_settings_diff(now() - interval '10 min', now()) s LEFT JOIN pg_database d ON d.oid = s.setdatabase WHERE name = 'work_mem' ORDER BY 1, 2, 3;
ALTER DATABASE postgres RESET work_mem;
ALTER ROLE postgres RESET work_mem;
ALTER ROLE postgres IN DATABASE postgres RESET work_mem;
-- test pg_reboot
SELECT COUNT(*) FROM public.pg_reboot;
SELECT now() - ts > interval '2 second' FROM pg_reboot;
-- test the reset
SELECT * FROM pg_track_settings_reset();
SELECT COUNT(*) FROM public.pg_track_settings_history;
SELECT COUNT(*) FROM public.pg_track_settings_log('work_mem');
SELECT COUNT(*) FROM public.pg_track_settings_diff(now() - interval '1 hour', now());
SELECT COUNT(*) FROM public.pg_track_db_role_settings_log('work_mem');
SELECT COUNT(*) FROM public.pg_track_db_role_settings_diff(now() - interval '1 hour', now());
SELECT COUNT(*) FROM public.pg_reboot;
