-- This program is open source, licensed under the PostgreSQL License.
-- For license terms, see the LICENSE file.
--
-- Copyright (C) 2015-2025: Julien Rouhaud

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pg_track_settings" to load this file. \quit

SET client_encoding = 'UTF8';

CREATE TABLE pg_track_settings_list (
    name text PRIMARY KEY
);
SELECT pg_catalog.pg_extension_config_dump('pg_track_settings_list', '');

CREATE TABLE pg_track_settings_history (
    ts timestamp with time zone,
    name text NOT NULL,
    setting text,
    is_dropped boolean NOT NULL DEFAULT false,
    setting_pretty text,
    PRIMARY KEY(ts, name)
);
SELECT pg_catalog.pg_extension_config_dump('pg_track_settings_history', '');

CREATE TABLE pg_track_db_role_settings_list (
    name text,
    setdatabase oid,
    setrole oid,
    PRIMARY KEY (name, setdatabase, setrole)
);
SELECT pg_catalog.pg_extension_config_dump('pg_track_db_role_settings_list', '');

CREATE TABLE pg_track_db_role_settings_history (
    ts timestamp with time zone,
    name text,
    setdatabase oid,
    setrole oid,
    setting text,
    is_dropped boolean NOT NULL DEFAULT false,
    PRIMARY KEY(ts, name, setdatabase, setrole)
);
SELECT pg_catalog.pg_extension_config_dump('pg_track_db_role_settings_history', '');

CREATE TABLE pg_reboot (
    ts timestamp with time zone PRIMARY KEY
);
SELECT pg_catalog.pg_extension_config_dump('pg_reboot', '');

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
        INSERT INTO pg_track_settings_history (ts, name, setting,
            setting_pretty, is_dropped)
        SELECT now(), name, NULL, NULL, true
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
    INSERT INTO pg_track_settings_history (ts, name, setting, setting_pretty)
    SELECT now(), s.name, s.setting, pg_catalog.current_setting(s.name)
    FROM pg_settings s
    LEFT JOIN last_snapshot l ON l.name = s.name
    WHERE l.name IS NULL
    OR l.setting IS DISTINCT FROM s.setting;

    -- Handle dropped db_role_setting
    WITH rds AS (
        SELECT setdatabase, setrole,
            (regexp_split_to_array(unnest(setconfig),'=')::text[])[1] as name,
            (regexp_split_to_array(unnest(setconfig),'=')::text[])[2] as setting
        FROM pg_db_role_setting
    ),
    dropped AS (
        SELECT l.setdatabase, l.setrole, l.name
        FROM pg_track_db_role_settings_list l
        LEFT JOIN rds s ON (
            s.setdatabase = l.setdatabase
            AND s.setrole = l.setrole
            AND s.name = l.name
        )
        WHERE s.setdatabase IS NULL
            AND s.setrole IS NULL
            AND s.name IS NULL
    ),
    mark_dropped AS (
        INSERT INTO pg_track_db_role_settings_history
            (ts, setdatabase, setrole, name, setting, is_dropped)
        SELECT now(), setdatabase, setrole, name, NULL, true
        FROM dropped
    )
    DELETE FROM pg_track_db_role_settings_list l
    USING dropped d
    WHERE
        d.setdatabase = l.setdatabase
        AND d.setrole = l.setrole
        AND d.name = l.name;

    -- Insert missing settings
    WITH rds AS (
        SELECT setdatabase, setrole,
            (regexp_split_to_array(unnest(setconfig),'=')::text[])[1] as name,
            (regexp_split_to_array(unnest(setconfig),'=')::text[])[2] as setting
        FROM pg_db_role_setting
    )
    INSERT INTO pg_track_db_role_settings_list
        (setdatabase, setrole, name)
    SELECT setdatabase, setrole, name
    FROM rds s
    WHERE NOT EXISTS (SELECT 1
        FROM pg_track_db_role_settings_list l
        WHERE
            l.setdatabase = s.setdatabase
            AND l.setrole = l.setrole
            AND l.name = s.name
    );

    -- Detect changed GUC, insert new vals
    WITH rds AS (
        SELECT setdatabase, setrole,
            (regexp_split_to_array(unnest(setconfig),'=')::text[])[1] as name,
            (regexp_split_to_array(unnest(setconfig),'=')::text[])[2] as setting
        FROM pg_db_role_setting
    ),
    last_snapshot AS (
        SELECT setdatabase, setrole, name, setting
        FROM (
            SELECT setdatabase, setrole, name, setting,
                row_number() OVER (PARTITION BY name, setdatabase, setrole ORDER BY ts DESC) rownum
            FROM pg_track_db_role_settings_history
        ) all_snapshots
        WHERE rownum = 1
    )
    INSERT INTO pg_track_db_role_settings_history
        (ts, setdatabase, setrole, name, setting)
    SELECT now(), s.setdatabase, s.setrole, s.name, s.setting
    FROM rds s
    LEFT JOIN last_snapshot l ON
        l.setdatabase = s.setdatabase
        AND l.setrole = s.setrole
        AND l.name = s.name
    WHERE l.setdatabase IS NULL
        AND l.setrole IS NULL
        AND l.name IS NULL
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
/* end of pg_track_settings_snapshot() */

CREATE OR REPLACE FUNCTION pg_track_settings(_ts timestamp with time zone DEFAULT now())
RETURNS TABLE (name text, setting text, setting_pretty text) AS
$_$
BEGIN
    RETURN QUERY
        SELECT s.name, s.setting, s.setting_pretty
        FROM (
            SELECT h.name, h.setting, h.setting_pretty, h.is_dropped,
            row_number() OVER (PARTITION BY h.name ORDER BY h.ts DESC) AS rownum
            FROM pg_track_settings_history h
            WHERE ts <= _ts
        ) s
        WHERE s.rownum = 1
        AND NOT s.is_dropped
        ORDER BY s.name;
END;
$_$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_track_db_role_settings(_ts timestamp with time zone DEFAULT now())
RETURNS TABLE (setdatabase oid, setrole oid, name text, setting text) AS
$_$
BEGIN
    RETURN QUERY
        SELECT s.setdatabase, s.setrole, s.name, s.setting
        FROM (
            SELECT h.setdatabase, h.setrole, h.name, h.setting, h.is_dropped,
                row_number() OVER (PARTITION BY h.name, h.setdatabase, h.setrole ORDER BY h.ts DESC) AS rownum
            FROM pg_track_db_role_settings_history h
            WHERE ts <= _ts
        ) s
        WHERE s.rownum = 1
        AND NOT s.is_dropped
        ORDER BY s.setdatabase, s.setrole, s.name;
END;
$_$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_track_settings_diff(_from timestamp with time zone, _to timestamp with time zone)
RETURNS TABLE (name text, from_setting text, from_exists boolean,
    to_setting text, to_exists boolean,
    from_setting_pretty text, to_setting_pretty text) AS
$_$
BEGIN
    RETURN QUERY
        SELECT COALESCE(s1.name, s2.name),
               s1.setting AS from_setting,
               CASE WHEN s1.setting IS NULL THEN false ELSE true END,
               s2.setting AS to_setting,
               CASE WHEN s2.setting IS NULL THEN false ELSE true END,
               s1.setting_pretty AS from_setting_pretty,
               s2.setting_pretty AS to_setting_pretty
        FROM pg_track_settings(_from) s1
        FULL OUTER JOIN pg_track_settings(_to) s2 ON s2.name = s1.name
        WHERE s1.setting IS DISTINCT FROM s2.setting
        ORDER BY 1;
END;
$_$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_track_db_role_settings_diff(_from timestamp with time zone, _to timestamp with time zone)
RETURNS TABLE (setdatabase oid, setrole oid, name text,
    from_setting text, from_exists boolean, to_setting text, to_exists boolean)
AS
$_$
BEGIN
    RETURN QUERY
        SELECT COALESCE(s1.setdatabase, s2.setdatabase),
               COALESCE(s1.setrole, s2.setrole),
               COALESCE(s1.name, s2.name),
               s1.setting AS from_setting,
               CASE WHEN s1.setting IS NULL THEN false ELSE true END,
               s2.setting AS to_setting,
               CASE WHEN s2.setting IS NULL THEN false ELSE true END
        FROM pg_track_db_role_settings(_from) s1
        FULL OUTER JOIN pg_track_db_role_settings(_to) s2 ON
            s2.setdatabase = s1.setdatabase
            AND s2.setrole = s1.setrole
            AND s2.name = s1.name
        WHERE
            s1.setdatabase IS DISTINCT FROM s2.setdatabase
            AND s1.setrole IS DISTINCT FROM s2.setrole
            AND s1.setting IS DISTINCT FROM s2.setting
        ORDER BY 1, 2, 3;
END;
$_$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_track_settings_log(_name text)
RETURNS TABLE (ts timestamp with time zone, name text, setting_exists boolean,
    setting text, setting_pretty text) AS
$_$
BEGIN
    RETURN QUERY
        SELECT h.ts, h.name, NOT h.is_dropped, h.setting, h.setting_pretty
        FROM pg_track_settings_history h
        WHERE h.name = _name
        ORDER BY ts DESC;
END;
$_$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_track_db_role_settings_log(_name text)
RETURNS TABLE (ts timestamp with time zone, setdatabase oid, setrole oid,
    name text, setting_exists boolean, setting text) AS
$_$
BEGIN
    RETURN QUERY
        SELECT h.ts, h.setdatabase, h.setrole, h.name, NOT h.is_dropped, h.setting
        FROM pg_track_db_role_settings_history h
        WHERE h.name = _name
        ORDER BY ts, setdatabase, setrole DESC;
END;
$_$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_track_settings_reset()
RETURNS void AS
$_$
BEGIN
    TRUNCATE pg_track_settings_list;
    TRUNCATE pg_track_settings_history;
    TRUNCATE pg_track_db_role_settings_list;
    TRUNCATE pg_track_db_role_settings_history;
    TRUNCATE pg_reboot;
END;
$_$
LANGUAGE plpgsql;
