-- This program is open source, licensed under the PostgreSQL License.
-- For license terms, see the LICENSE file.
--
-- Copyright (C) 2015-2025: Julien Rouhaud

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pg_track_settings" to load this file. \quit

SET client_encoding = 'UTF8';

CREATE UNLOGGED TABLE public.pg_track_settings_settings_src_tmp (
    srvid integer NOT NULL,
    ts timestamp with time zone NOT NULL,
    name    text NOT NULL,
    setting text,
    current_setting text
);
-- no need to backup this table

CREATE TABLE public.pg_track_settings_list (
    srvid integer NOT NULL,
    name text,
    PRIMARY KEY (srvid, name)
);
SELECT pg_catalog.pg_extension_config_dump('public.pg_track_settings_list', '');

CREATE TABLE public.pg_track_settings_history (
    srvid integer NOT NULL,
    ts timestamp with time zone,
    name text NOT NULL,
    setting text,
    is_dropped boolean NOT NULL DEFAULT false,
    setting_pretty text,
    PRIMARY KEY(srvid, ts, name)
);
SELECT pg_catalog.pg_extension_config_dump('public.pg_track_settings_history', '');

CREATE UNLOGGED TABLE public.pg_track_settings_rds_src_tmp (
    srvid integer NOT NULL,
    ts timestamp with time zone NOT NULL,
    name text NOT NULL,
    setting text,
    setdatabase oid NOT NULL,
    setrole oid NOT NULL
);
-- no need to backup this table

CREATE TABLE public.pg_track_db_role_settings_list (
    srvid integer,
    name text,
    setdatabase oid,
    setrole oid,
    PRIMARY KEY (srvid, name, setdatabase, setrole)
);
SELECT pg_catalog.pg_extension_config_dump('public.pg_track_db_role_settings_list', '');

CREATE TABLE public.pg_track_db_role_settings_history (
    srvid INTEGER NOT NULL,
    ts timestamp with time zone,
    name text,
    setdatabase oid,
    setrole oid,
    setting text,
    is_dropped boolean NOT NULL DEFAULT false,
    PRIMARY KEY(srvid, ts, name, setdatabase, setrole)
);
SELECT pg_catalog.pg_extension_config_dump('public.pg_track_db_role_settings_history', '');

CREATE UNLOGGED TABLE public.pg_track_settings_reboot_src_tmp (
    srvid integer NOT NULL,
    ts timestamp with time zone NOT NULL,
    postmaster_ts timestamp with time zone NOT NULL
);
-- no need to backup this table

CREATE TABLE public.pg_reboot (
    srvid integer NOT NULL,
    ts timestamp with time zone,
    PRIMARY KEY (srvid, ts)
);
SELECT pg_catalog.pg_extension_config_dump('public.pg_reboot', '');

----------------------
-- source functions --
----------------------
CREATE OR REPLACE FUNCTION pg_track_settings_settings_src (
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
        FROM public.pg_track_settings_settings_src_tmp s;
    END IF;
END;
$PROC$ LANGUAGE plpgsql; /* end of pg_track_settings_settings_src */

CREATE OR REPLACE FUNCTION pg_track_settings_rds_src (
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
        FROM public.pg_track_settings_rds_src_tmp s;
    END IF;
END;
$PROC$ LANGUAGE plpgsql; /* end of pg_track_settings_rds_src */

CREATE OR REPLACE FUNCTION pg_track_settings_reboot_src (
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
        FROM public.pg_track_settings_reboot_src_tmp s;
    END IF;
END;
$PROC$ LANGUAGE plpgsql; /* end of pg_track_settings_reboot_src */

------------------------
-- snapshot functions --
------------------------
CREATE OR REPLACE FUNCTION pg_track_settings_snapshot_settings(_srvid integer)
    RETURNS boolean AS
$_$
DECLARE
    _snap_ts timestamp with time zone = NULL;
BEGIN
    SELECT max(ts) INTO _snap_ts
    FROM public.pg_track_settings_settings_src(_srvid);

    -- this function should have been called for previously saved data.  If
    -- not, probably somethig went wrong, so discard those data
    IF (_srvid != 0) THEN
        DELETE FROM public.pg_track_settings_settings_src_tmp
        WHERE ts != _snap_ts;
    END IF;

    -- Handle dropped GUC
    WITH src AS (
        SELECT * FROM public.pg_track_settings_settings_src(_srvid)
    ),
    dropped AS (
        SELECT s.ts, l.srvid, l.name
        FROM public.pg_track_settings_list l
        LEFT JOIN src s ON s.name = l.name
        WHERE l.srvid = _srvid
          AND s.name IS NULL
    ),
    mark_dropped AS (
        INSERT INTO public.pg_track_settings_history (srvid, ts, name, setting,
            setting_pretty, is_dropped)
        SELECT srvid, COALESCE(_snap_ts, now()), name, NULL, NULL, true
        FROM dropped
    )
    DELETE FROM public.pg_track_settings_list l
    USING dropped d
    WHERE d.name = l.name
      AND d.srvid = l.srvid
      AND l.srvid = _srvid;

    -- Insert missing settings
    INSERT INTO public.pg_track_settings_list (srvid, name)
    SELECT _srvid, name
    FROM public.pg_track_settings_settings_src(_srvid) s
    WHERE NOT EXISTS (SELECT 1
        FROM public.pg_track_settings_list l
        WHERE l.srvid = _srvid
          AND l.name = s.name
    );

    -- Detect changed GUC, insert new vals
    WITH src AS (
        SELECT * FROM public.pg_track_settings_settings_src(_srvid)
    ), last_snapshot AS (
        SELECT srvid, name, setting
        FROM (
            SELECT srvid, name, setting,
              row_number() OVER (PARTITION BY NAME ORDER BY ts DESC) AS rownum
            FROM public.pg_track_settings_history h
            WHERE h.srvid = _srvid
        ) all_snapshots
        WHERE rownum = 1
    )
    INSERT INTO public.pg_track_settings_history
      (srvid, ts, name, setting, setting_pretty)
    SELECT _srvid, s.ts, s.name, s.setting, s.current_setting
    FROM src s
    LEFT JOIN last_snapshot l ON l.name = s.name
    WHERE (
        l.name IS NULL
        OR l.setting IS DISTINCT FROM s.setting
    );

    IF (_srvid != 0) THEN
        DELETE FROM public.pg_track_settings_settings_src_tmp
        WHERE srvid = _srvid;
    END IF;

    RETURN true;
END;
$_$
LANGUAGE plpgsql; /* end of pg_track_settings_snapshot_settings() */

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

CREATE OR REPLACE FUNCTION public.pg_track_settings_snapshot_reboot(_srvid integer)
    RETURNS boolean AS
$_$
BEGIN
    -- Detect is postmaster restarted since last call
    WITH last_reboot AS (
        SELECT t.postmaster_ts
        FROM public.pg_track_settings_reboot_src(_srvid) t
    )
    INSERT INTO public.pg_reboot (srvid, ts)
    SELECT _srvid, lr.postmaster_ts FROM last_reboot lr
    WHERE NOT EXISTS (SELECT 1
        FROM public.pg_reboot r
        WHERE r.srvid = _srvid
        AND r.ts = lr.postmaster_ts
        AND r.srvid = _srvid
    );

    IF (_srvid != 0) THEN
        DELETE FROM public.pg_track_settings_reboot_src_tmp
        WHERE srvid = _srvid;
    END IF;

    RETURN true;
END;
$_$
LANGUAGE plpgsql; /* end of pg_track_settings_snapshot_reboot() */

-- global function doing all the work for local instance, kept for backward
-- compatibility
CREATE OR REPLACE FUNCTION pg_track_settings_snapshot()
RETURNS boolean AS
$_$
BEGIN
    PERFORM public.pg_track_settings_snapshot_settings(0);
    PERFORM public.pg_track_settings_snapshot_rds(0);
    PERFORM public.pg_track_settings_snapshot_reboot(0);

    RETURN true;
END;
$_$
LANGUAGE plpgsql;
/* end of pg_track_settings_snapshot() */

CREATE OR REPLACE FUNCTION public.pg_track_settings(
    _ts timestamp with time zone DEFAULT now(),
    _srvid integer DEFAULT 0)
RETURNS TABLE (name text, setting text, setting_pretty text) AS
$_$
BEGIN
    RETURN QUERY
        SELECT s.name, s.setting, s.setting_pretty
        FROM (
            SELECT h.name, h.setting, h.setting_pretty, h.is_dropped,
            row_number() OVER (PARTITION BY h.name ORDER BY h.ts DESC) AS rownum
            FROM public.pg_track_settings_history h
            WHERE h.srvid = _srvid
            AND h.ts <= _ts
        ) s
        WHERE s.rownum = 1
        AND NOT s.is_dropped
        ORDER BY s.name;
END;
$_$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION public.pg_track_db_role_settings(
    _ts timestamp with time zone DEFAULT now(),
    _srvid integer DEFAULT 0)
RETURNS TABLE (setdatabase oid, setrole oid, name text, setting text) AS
$_$
BEGIN
    RETURN QUERY
        SELECT s.setdatabase, s.setrole, s.name, s.setting
        FROM (
            SELECT h.setdatabase, h.setrole, h.name, h.setting, h.is_dropped,
                row_number() OVER (PARTITION BY h.name, h.setdatabase, h.setrole ORDER BY h.ts DESC) AS rownum
            FROM public.pg_track_db_role_settings_history h
            WHERE h.srvid = _srvid
            AND h.ts <= _ts
        ) s
        WHERE s.rownum = 1
        AND NOT s.is_dropped
        ORDER BY s.setdatabase, s.setrole, s.name;
END;
$_$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION public.pg_track_settings_diff(
    _from timestamp with time zone,
    _to timestamp with time zone,
    _srvid integer DEFAULT 0)
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
        FROM public.pg_track_settings(_from, _srvid) s1
        FULL OUTER JOIN public.pg_track_settings(_to, _srvid) s2 ON s2.name = s1.name
        WHERE s1.setting IS DISTINCT FROM s2.setting
        ORDER BY 1;
END;
$_$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION public.pg_track_db_role_settings_diff(
    _from timestamp with time zone,
    _to timestamp with time zone,
    _srvid integer DEFAULT 0)
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
        FROM public.pg_track_db_role_settings(_from, _srvid) s1
        FULL OUTER JOIN public.pg_track_db_role_settings(_to, _srvid) s2 ON
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

CREATE OR REPLACE FUNCTION pg_track_settings_log(
    _name text,
    _srvid integer DEFAULT 0)
RETURNS TABLE (ts timestamp with time zone, name text, setting_exists boolean,
    setting text, setting_pretty text) AS
$_$
BEGIN
    RETURN QUERY
        SELECT h.ts, h.name, NOT h.is_dropped, h.setting, h.setting_pretty
        FROM public.pg_track_settings_history h
        WHERE h.srvid = _srvid
        AND h.name = _name
        ORDER BY ts DESC;
END;
$_$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_track_db_role_settings_log(
    _name text,
    _srvid integer DEFAULT 0)
RETURNS TABLE (ts timestamp with time zone, setdatabase oid, setrole oid,
    name text, setting_exists boolean, setting text) AS
$_$
BEGIN
    RETURN QUERY
        SELECT h.ts, h.setdatabase, h.setrole, h.name, NOT h.is_dropped, h.setting
        FROM public.pg_track_db_role_settings_history h
        WHERE h.srvid = _srvid
        AND h.name = _name
        ORDER BY ts, setdatabase, setrole DESC;
END;
$_$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_track_reboot_log(_srvid integer DEFAULT 0)
RETURNS TABLE (ts timestamp with time zone) AS
$_$
BEGIN
    RETURN QUERY
        SELECT r.ts
        FROM public.pg_reboot r
        WHERE r.srvid = _srvid
        ORDER BY r.ts;
END;
$_$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION public.pg_track_settings_reset(_srvid integer DEFAULT 0)
RETURNS void AS
$_$
BEGIN
    DELETE FROM public.pg_track_settings_settings_src_tmp WHERE srvid = _srvid;
    DELETE FROM public.pg_track_settings_rds_src_tmp WHERE srvid = _srvid;
    DELETE FROM public.pg_track_settings_reboot_src_tmp WHERE srvid = _srvid;
    DELETE FROM public.pg_track_settings_list WHERE srvid = _srvid;
    DELETE FROM public.pg_track_settings_history WHERE srvid = _srvid;
    DELETE FROM public.pg_track_db_role_settings_list WHERE srvid = _srvid;
    DELETE FROM public.pg_track_db_role_settings_history WHERE srvid = _srvid;
    DELETE FROM public.pg_reboot WHERE srvid = _srvid;
END;
$_$
LANGUAGE plpgsql;
