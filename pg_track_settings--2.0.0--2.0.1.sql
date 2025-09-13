-- This program is open source, licensed under the PostgreSQL License.
-- For license terms, see the LICENSE file.
--
-- Copyright (C) 2015-2025: Julien Rouhaud

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_track_settings" to load this file. \quit

SET LOCAL client_encoding = 'UTF8';

CREATE OR REPLACE FUNCTION pg_track_settings_snapshot_rds(_srvid integer)
    RETURNS boolean AS
$_$
DECLARE
    _snap_ts timestamp with time zone;
BEGIN
    SELECT max(ts) INTO _snap_ts
    FROM public.pg_track_settings_rds_src(_srvid);

    -- this function should have been called for previously saved data.  If
    -- not, probably somethig went wrong, so discard those data
    IF (_srvid != 0) THEN
        DELETE FROM public.pg_track_settings_rds_src_tmp
        WHERE ts != _snap_ts;
    END IF;

    -- Handle dropped db_role_setting
    WITH rds AS (
        SELECT * FROM public.pg_track_settings_rds_src(_srvid)
    ),
    dropped AS (
        SELECT _snap_ts AS ts, l.setdatabase, l.setrole, l.name
        FROM public.pg_track_db_role_settings_list l
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
        INSERT INTO public.pg_track_db_role_settings_history
            (srvid, ts, setdatabase, setrole, name, setting, is_dropped)
        SELECT _srvid, ts, d.setdatabase, d.setrole, d.name, NULL, true
        FROM dropped AS d
    )
    DELETE FROM public.pg_track_db_role_settings_list l
    USING dropped d
    WHERE
        l.srvid = _srvid
        AND d.setdatabase = l.setdatabase
        AND d.setrole = l.setrole
        AND d.name = l.name;

    -- Insert missing settings
    WITH rds AS (
        SELECT * FROM public.pg_track_settings_rds_src(_srvid)
    )
    INSERT INTO public.pg_track_db_role_settings_list
        (srvid, setdatabase, setrole, name)
    SELECT _srvid, setdatabase, setrole, name
    FROM rds s
    WHERE NOT EXISTS (SELECT 1
        FROM public.pg_track_db_role_settings_list l
        WHERE
            l.srvid = _srvid
            AND l.setdatabase = s.setdatabase
            AND l.setrole = l.setrole
            AND l.name = s.name
    );

    -- Detect changed GUC, insert new vals
    WITH rds AS (
        SELECT * FROM public.pg_track_settings_rds_src(_srvid)
    ),
    last_snapshot AS (
        SELECT setdatabase, setrole, name, setting
        FROM (
            SELECT setdatabase, setrole, name, setting,
                row_number() OVER (PARTITION BY name, setdatabase, setrole ORDER BY ts DESC) AS rownum
            FROM public.pg_track_db_role_settings_history
            WHERE srvid = _srvid
        ) all_snapshots
        WHERE rownum = 1
    )
    INSERT INTO public.pg_track_db_role_settings_history
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
        DELETE FROM public.pg_track_settings_rds_src_tmp
        WHERE srvid = _srvid;
    END IF;

    RETURN true;
END;
$_$
LANGUAGE plpgsql; /* end of pg_track_settings_snapshot_rds() */
