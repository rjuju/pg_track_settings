\echo Use "CREATE EXTENSION pg_track_settings" to load this file. \quit

SET client_encoding = 'UTF8';

CREATE TABLE pg_track_settings_list (
    name text PRIMARY KEY
);

CREATE TABLE pg_track_settings_history (
    ts timestamp with time zone,
    name text,
    setting text,
    is_dropped boolean NOT NULL DEFAULT false,
    PRIMARY KEY(ts, name)
);

CREATE TABLE pg_reboot (
    ts timestamp with time zone PRIMARY KEY
);

CREATE OR REPLACE FUNCTION pg_track_settings_snapshot() RETURNS boolean AS
$_$
BEGIN
    -- Handle dropped GUC
    WITH dropped AS (
        SELECT l.name
        FROM pg_track_settings_list l
        LEFT JOIN pg_settings s ON s.name = l.name
        WHERE s.name IS NULL
    ),
    mark_dropped AS (
        INSERT INTO pg_track_settings_history (ts, name, setting, is_dropped)
        SELECT now(), name, NULL, true
        FROM dropped
    )
    DELETE FROM pg_track_settings_list l
    USING dropped d
    WHERE d.name = l.name;

    -- Insert missing settings
    INSERT INTO pg_track_settings_list (name)
    SELECT name
    FROM pg_settings s
    WHERE NOT EXISTS (SELECT 1
        FROM pg_track_settings_list l
        WHERE l.name = s.name
    );

    -- Detect changed GUC, insert new vals
    WITH last_snapshot AS (
        SELECT name, setting
        FROM (
            SELECT name, setting, row_number() OVER (PARTITION BY NAME ORDER BY ts DESC) rownum
            FROM pg_track_settings_history
        ) all_snapshots
        WHERE rownum = 1
    )
    INSERT INTO pg_track_settings_history (ts, name, setting)
    SELECT now(), s.name, s.setting
    FROM pg_settings s
    LEFT JOIN last_snapshot l ON l.name = s.name
    WHERE l.name IS NULL
    OR l.setting IS DISTINCT FROM s.setting;

    -- Detect is postmaster restarted since last call
    WITH last_reboot AS (
        SELECT t FROM pg_postmaster_start_time() t
    )
    INSERT INTO pg_reboot (ts)
    SELECT t FROM last_reboot lr
    WHERE NOT EXISTS (SELECT 1
        FROM pg_reboot r
        WHERE r.ts = lr.t
    );

    RETURN true;
END;
$_$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_track_settings(_ts timestamp with time zone DEFAULT now())
RETURNS TABLE (name text, setting text) AS
$_$
BEGIN
    RETURN QUERY
        SELECT s.name, s.setting
        FROM (
            SELECT h.name, h.setting, h.is_dropped, row_number() OVER (PARTITION BY h.name ORDER BY h.ts DESC) AS rownum
            FROM pg_track_settings_history h
            WHERE ts <= _ts
        ) s
        WHERE s.rownum = 1
        AND NOT s.is_dropped
        ORDER BY s.name;
END;
$_$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_track_settings_diff(_from timestamp with time zone, _to timestamp with time zone)
RETURNS TABLE (name text, from_setting text, from_exists boolean, to_setting text, to_exists boolean) AS
$_$
BEGIN
    RETURN QUERY
        SELECT COALESCE(s1.name, s2.name),
               s1.setting AS from_setting,
               CASE WHEN s1.setting IS NULL THEN false ELSE true END,
               s2.setting AS to_setting,
               CASE WHEN s2.setting IS NULL THEN false ELSE true END
        FROM pg_track_settings(_from) s1
        FULL OUTER JOIN pg_track_settings(_to) s2 ON s2.name = s1.name
        WHERE s1.setting IS DISTINCT FROM s2.setting
        ORDER BY 1;
END;
$_$
LANGUAGE plpgsql;
