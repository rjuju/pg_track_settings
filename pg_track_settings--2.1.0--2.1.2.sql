-- This program is open source, licensed under the PostgreSQL License.
-- For license terms, see the LICENSE file.
--
-- Copyright (C) 2015-2025: Julien Rouhaud

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_track_settings" to load this file. \quit

CREATE OR REPLACE FUNCTION @extschema@.pg_track_settings_settings_src (
    IN _srvid integer,
    OUT ts timestamp with time zone,
    OUT name text,
    OUT setting text,
    OUT current_setting text
)
RETURNS SETOF record AS $PROC$
BEGIN
    IF (_srvid = 0) THEN
        RETURN QUERY SELECT now(),
            s.name, s.setting, pg_catalog.current_setting(s.name)
        FROM pg_catalog.pg_settings s;
    ELSE
        RETURN QUERY SELECT s.ts,
            s.name, s.setting, s.current_setting
        FROM @extschema@.pg_track_settings_settings_src_tmp s
        WHERE srvid = _srvid;
    END IF;
END;
$PROC$ LANGUAGE plpgsql; /* end of pg_track_settings_settings_src */

CREATE OR REPLACE FUNCTION @extschema@.pg_track_settings_rds_src (
    IN _srvid integer,
    OUT ts timestamp with time zone,
    OUT name text,
    OUT setting text,
    OUT setdatabase oid,
    OUT setrole oid
)
RETURNS SETOF record AS $PROC$
BEGIN
    IF (_srvid = 0) THEN
        RETURN QUERY SELECT now(),
            (regexp_split_to_array(unnest(s.setconfig),'=')::text[])[1] AS name,
            (regexp_split_to_array(unnest(s.setconfig),'=')::text[])[2] AS setting,
            s.setdatabase, s.setrole
        FROM pg_catalog.pg_db_role_setting s;
    ELSE
        RETURN QUERY SELECT s.ts,
            s.name, s.setting, s.setdatabase, s.setrole
        FROM @extschema@.pg_track_settings_rds_src_tmp s
        WHERE srvid = _srvid;
    END IF;
END;
$PROC$ LANGUAGE plpgsql; /* end of pg_track_settings_rds_src */

CREATE OR REPLACE FUNCTION @extschema@.pg_track_settings_reboot_src (
    IN _srvid integer,
    OUT ts timestamp with time zone,
    OUT postmaster_ts timestamp with time zone
)
RETURNS SETOF record AS $PROC$
BEGIN
    IF (_srvid = 0) THEN
        RETURN QUERY SELECT now(),
            pg_postmaster_start_time();
    ELSE
        RETURN QUERY SELECT s.ts,
            s.postmaster_ts
        FROM @extschema@.pg_track_settings_reboot_src_tmp s
        WHERE srvid = _srvid;
    END IF;
END;
$PROC$ LANGUAGE plpgsql; /* end of pg_track_settings_reboot_src */

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
        WHERE ts != _snap_ts
        AND srvid = _srvid;
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
    -- If all pg_db_role_setting have been removed, we won't get a snapshot ts
    -- but we may still have to record that some settings have been removed.
    -- In that case simply use now(), as that extension doesn't guarantee the
    -- timestamp to be more precise than the snapshot interval, and there's
    -- isn't any better timestamp to use anyway.
    SELECT coalesce(max(ts), now()) INTO _snap_ts
    FROM @extschema@.pg_track_settings_rds_src(_srvid);

    -- this function should have been called for previously saved data.  If
    -- not, probably somethig went wrong, so discard those data
    IF (_srvid != 0) THEN
        DELETE FROM @extschema@.pg_track_settings_rds_src_tmp
        WHERE ts != _snap_ts
        AND srvid = _srvid;
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
