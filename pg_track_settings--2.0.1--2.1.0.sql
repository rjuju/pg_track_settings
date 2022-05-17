-- This program is open source, licensed under the PostgreSQL License.
-- For license terms, see the LICENSE file.
--
-- Copyright (C) 2015-2022: Julien Rouhaud

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_track_settings" to load this file. \quit

SET LOCAL client_encoding = 'UTF8';

CREATE OR REPLACE FUNCTION @extschema@.pg_track_settings_snapshot_settings(_srvid integer)
    RETURNS boolean AS
$_$
DECLARE
    _snap_ts timestamp with time zone = NULL;
BEGIN
    SELECT max(ts) INTO _snap_ts
    FROM @extschema@.pg_track_settings_settings_src(_srvid);

    -- this function should have been called for previously saved data.  If
    -- not, probably somethig went wrong, so discard those data
    IF (_srvid != 0) THEN
        DELETE FROM @extschema@.pg_track_settings_settings_src_tmp
        WHERE ts != _snap_ts;
    END IF;

    -- Handle dropped GUC
    WITH src AS (
        SELECT * FROM @extschema@.pg_track_settings_settings_src(_srvid)
    ),
    dropped AS (
        SELECT s.ts, l.srvid, l.name
        FROM @extschema@.pg_track_settings_list l
        LEFT JOIN src s ON s.name = l.name
        WHERE l.srvid = _srvid
          AND s.name IS NULL
    ),
    mark_dropped AS (
        INSERT INTO @extschema@.pg_track_settings_history (srvid, ts, name, setting,
            setting_pretty, is_dropped)
        SELECT srvid, COALESCE(_snap_ts, now()), name, NULL, NULL, true
        FROM dropped
    )
    DELETE FROM @extschema@.pg_track_settings_list l
    USING dropped d
    WHERE d.name = l.name
      AND d.srvid = l.srvid
      AND l.srvid = _srvid;

    -- Insert missing settings
    INSERT INTO @extschema@.pg_track_settings_list (srvid, name)
    SELECT _srvid, name
    FROM @extschema@.pg_track_settings_settings_src(_srvid) s
    WHERE NOT EXISTS (SELECT 1
        FROM @extschema@.pg_track_settings_list l
        WHERE l.srvid = _srvid
          AND l.name = s.name
    );

    -- Detect changed GUC, insert new vals
    WITH src AS (
        SELECT * FROM @extschema@.pg_track_settings_settings_src(_srvid)
    ), last_snapshot AS (
        SELECT srvid, name, setting
        FROM (
            SELECT srvid, name, setting,
              row_number() OVER (PARTITION BY NAME ORDER BY ts DESC) AS rn
            FROM @extschema@.pg_track_settings_history h
            WHERE h.srvid = _srvid
        ) all_snapshots
        WHERE all_snapshots.rn = 1
    )
    INSERT INTO @extschema@.pg_track_settings_history
      (srvid, ts, name, setting, setting_pretty)
    SELECT _srvid, s.ts, s.name, s.setting, s.current_setting
    FROM src s
    LEFT JOIN last_snapshot l ON l.name = s.name
    WHERE (
        l.name IS NULL
        OR l.setting IS DISTINCT FROM s.setting
    );

    IF (_srvid != 0) THEN
        DELETE FROM @extschema@.pg_track_settings_settings_src_tmp
        WHERE srvid = _srvid;
    END IF;

    RETURN true;
END;
$_$
LANGUAGE plpgsql; /* end of pg_track_settings_snapshot_settings() */

CREATE OR REPLACE FUNCTION @extschema@.pg_track_settings_snapshot_rds(_srvid integer)
    RETURNS boolean AS
$_$
DECLARE
    _snap_ts timestamp with time zone;
BEGIN
    SELECT max(ts) INTO _snap_ts
    FROM @extschema@.pg_track_settings_rds_src(_srvid);

    -- this function should have been called for previously saved data.  If
    -- not, probably somethig went wrong, so discard those data
    IF (_srvid != 0) THEN
        DELETE FROM @extschema@.pg_track_settings_rds_src_tmp
        WHERE ts != _snap_ts;
    END IF;

    -- Handle dropped db_role_setting
    WITH rds AS (
        SELECT * FROM @extschema@.pg_track_settings_rds_src(_srvid)
    ),
    dropped AS (
        SELECT _snap_ts AS ts, l.setdatabase, l.setrole, l.name
        FROM @extschema@.pg_track_db_role_settings_list l
        LEFT JOIN rds s ON (
            s.setdatabase = l.setdatabase
            AND s.setrole = l.setrole
            AND s.name = l.name
        )
        WHERE l.srvid = _srvid
            AND s.setdatabase IS NULL
            AND s.setrole IS NULL
            AND s.name IS NULL
    ),
    mark_dropped AS (
        INSERT INTO @extschema@.pg_track_db_role_settings_history
            (srvid, ts, setdatabase, setrole, name, setting, is_dropped)
        SELECT _srvid, ts, d.setdatabase, d.setrole, d.name, NULL, true
        FROM dropped AS d
    )
    DELETE FROM @extschema@.pg_track_db_role_settings_list l
    USING dropped d
    WHERE
        l.srvid = _srvid
        AND d.setdatabase = l.setdatabase
        AND d.setrole = l.setrole
        AND d.name = l.name;

    -- Insert missing settings
    WITH rds AS (
        SELECT * FROM @extschema@.pg_track_settings_rds_src(_srvid)
    )
    INSERT INTO @extschema@.pg_track_db_role_settings_list
        (srvid, setdatabase, setrole, name)
    SELECT _srvid, setdatabase, setrole, name
    FROM rds s
    WHERE NOT EXISTS (SELECT 1
        FROM @extschema@.pg_track_db_role_settings_list l
        WHERE
            l.srvid = _srvid
            AND l.setdatabase = s.setdatabase
            AND l.setrole = l.setrole
            AND l.name = s.name
    );

    -- Detect changed GUC, insert new vals
    WITH rds AS (
        SELECT * FROM @extschema@.pg_track_settings_rds_src(_srvid)
    ),
    last_snapshot AS (
        SELECT setdatabase, setrole, name, setting
        FROM (
            SELECT setdatabase, setrole, name, setting,
                row_number() OVER (PARTITION BY name, setdatabase, setrole ORDER BY ts DESC) AS rn
            FROM @extschema@.pg_track_db_role_settings_history
            WHERE srvid = _srvid
        ) all_snapshots
        WHERE all_snapshots.rn = 1
    )
    INSERT INTO @extschema@.pg_track_db_role_settings_history
        (srvid, ts, setdatabase, setrole, name, setting)
    SELECT _srvid, s.ts, s.setdatabase, s.setrole, s.name, s.setting
    FROM rds s
    LEFT JOIN last_snapshot l ON
        l.setdatabase = s.setdatabase
        AND l.setrole = s.setrole
        AND l.name = s.name
    WHERE (l.setdatabase IS NULL
        AND l.setrole IS NULL
        AND l.name IS NULL)
    OR (l.setting IS DISTINCT FROM s.setting);

    IF (_srvid != 0) THEN
        DELETE FROM @extschema@.pg_track_settings_rds_src_tmp
        WHERE srvid = _srvid;
    END IF;

    RETURN true;
END;
$_$
LANGUAGE plpgsql; /* end of pg_track_settings_snapshot_rds() */

CREATE OR REPLACE FUNCTION @extschema@.pg_track_settings(
    _ts timestamp with time zone DEFAULT now(),
    _srvid integer DEFAULT 0)
RETURNS TABLE (name text, setting text, setting_pretty text) AS
$_$
BEGIN
    RETURN QUERY
        SELECT s.name, s.setting, s.setting_pretty
        FROM (
            SELECT h.name, h.setting, h.setting_pretty, h.is_dropped,
            row_number() OVER (PARTITION BY h.name ORDER BY h.ts DESC) AS rn
            FROM @extschema@.pg_track_settings_history h
            WHERE h.srvid = _srvid
            AND h.ts <= _ts
        ) s
        WHERE s.rn = 1
        AND NOT s.is_dropped
        ORDER BY s.name;
END;
$_$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION @extschema@.pg_track_db_role_settings(
    _ts timestamp with time zone DEFAULT now(),
    _srvid integer DEFAULT 0)
RETURNS TABLE (setdatabase oid, setrole oid, name text, setting text) AS
$_$
BEGIN
    RETURN QUERY
        SELECT s.setdatabase, s.setrole, s.name, s.setting
        FROM (
            SELECT h.setdatabase, h.setrole, h.name, h.setting, h.is_dropped,
                row_number() OVER (PARTITION BY h.name, h.setdatabase, h.setrole ORDER BY h.ts DESC) AS rn
            FROM @extschema@.pg_track_db_role_settings_history h
            WHERE h.srvid = _srvid
            AND h.ts <= _ts
        ) s
        WHERE s.rn = 1
        AND NOT s.is_dropped
        ORDER BY s.setdatabase, s.setrole, s.name;
END;
$_$
LANGUAGE plpgsql;
