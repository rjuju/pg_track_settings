-- This program is open source, licensed under the PostgreSQL License.
-- For license terms, see the LICENSE file.
--
-- Copyright (C) 2015-2026: Julien Rouhaud

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_track_settings" to load this file. \quit

CREATE UNLOGGED TABLE @extschema@.pg_track_settings_version_src_tmp (
    srvid integer NOT NULL,
    ts timestamp with time zone NOT NULL,
    version text NOT NULL,
    version_num integer NOT NULL
);
-- no need to backup this table

CREATE TABLE @extschema@.pg_track_version_history (
    srvid integer NOT NULL,
    ts timestamp with time zone,
    version text NOT NULL,
    version_num integer NOT NULL,
    PRIMARY KEY (srvid, ts)
);
SELECT pg_catalog.pg_extension_config_dump('@extschema@.pg_track_version_history', '');

CREATE OR REPLACE FUNCTION @extschema@.pg_track_settings_version_src (
    IN _srvid integer,
    OUT ts timestamp with time zone,
    OUT version text,
    OUT version_num integer
)
RETURNS SETOF record AS $PROC$
BEGIN
    IF (_srvid = 0) THEN
        -- use the postmaster start time, so that the recorded timestamp
        -- is the one of the version change itself (a version change always
        -- happens together with a restart), not the one of the snapshot
        -- that detected it
        RETURN QUERY SELECT pg_postmaster_start_time(),
            pg_catalog.current_setting('server_version'),
            pg_catalog.current_setting('server_version_num')::integer;
    ELSE
        RETURN QUERY SELECT s.ts,
            s.version, s.version_num
        FROM @extschema@.pg_track_settings_version_src_tmp s
        WHERE srvid = _srvid;
    END IF;
END;
$PROC$ LANGUAGE plpgsql; /* end of pg_track_settings_version_src */

CREATE OR REPLACE FUNCTION @extschema@.pg_track_settings_snapshot_version(_srvid integer)
    RETURNS boolean AS
$_$
DECLARE
    _r record;
    _last_ts timestamp with time zone;
    _last_version_num integer;
BEGIN
    -- Detect if server version changed since last call, and record each
    -- version change along with the postmaster start time at which it
    -- came into service
    SELECT t.ts, t.version_num INTO _last_ts, _last_version_num
    FROM (
        SELECT ts, version_num,
            row_number() OVER (ORDER BY ts DESC) AS rn
        FROM @extschema@.pg_track_version_history
        WHERE srvid = _srvid
    ) t
    WHERE t.rn = 1;

    FOR _r IN
        SELECT ts, version, version_num
        FROM @extschema@.pg_track_settings_version_src(_srvid)
        ORDER BY ts
    LOOP
        IF (_last_ts IS NULL OR _r.ts > _last_ts)
            AND _r.version_num IS DISTINCT FROM _last_version_num THEN
            INSERT INTO @extschema@.pg_track_version_history (srvid, ts, version,
                version_num)
            VALUES (_srvid, _r.ts, _r.version, _r.version_num);
            _last_ts := _r.ts;
            _last_version_num := _r.version_num;
        END IF;
    END LOOP;

    IF (_srvid != 0) THEN
        DELETE FROM @extschema@.pg_track_settings_version_src_tmp
        WHERE srvid = _srvid;
    END IF;

    RETURN true;
END;
$_$
LANGUAGE plpgsql; /* end of pg_track_settings_snapshot_version() */

-- global function doing all the work for local instance, kept for backward
-- compatibility
CREATE OR REPLACE FUNCTION @extschema@.pg_track_settings_snapshot()
RETURNS boolean AS
$_$
BEGIN
    PERFORM @extschema@.pg_track_settings_snapshot_settings(0);
    PERFORM @extschema@.pg_track_settings_snapshot_rds(0);
    PERFORM @extschema@.pg_track_settings_snapshot_reboot(0);
    PERFORM @extschema@.pg_track_settings_snapshot_version(0);

    RETURN true;
END;
$_$
LANGUAGE plpgsql;
/* end of pg_track_settings_snapshot() */

CREATE OR REPLACE FUNCTION @extschema@.pg_track_version_log(_srvid integer DEFAULT 0)
RETURNS TABLE (ts timestamp with time zone, version text, version_num integer) AS
$_$
BEGIN
    RETURN QUERY
        SELECT v.ts, v.version, v.version_num
        FROM @extschema@.pg_track_version_history v
        WHERE v.srvid = _srvid
        ORDER BY v.ts;
END;
$_$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION @extschema@.pg_track_settings_reset(_srvid integer DEFAULT 0)
RETURNS void AS
$_$
BEGIN
    DELETE FROM @extschema@.pg_track_settings_settings_src_tmp WHERE srvid = _srvid;
    DELETE FROM @extschema@.pg_track_settings_rds_src_tmp WHERE srvid = _srvid;
    DELETE FROM @extschema@.pg_track_settings_reboot_src_tmp WHERE srvid = _srvid;
    DELETE FROM @extschema@.pg_track_settings_version_src_tmp WHERE srvid = _srvid;
    DELETE FROM @extschema@.pg_track_settings_list WHERE srvid = _srvid;
    DELETE FROM @extschema@.pg_track_settings_history WHERE srvid = _srvid;
    DELETE FROM @extschema@.pg_track_db_role_settings_list WHERE srvid = _srvid;
    DELETE FROM @extschema@.pg_track_db_role_settings_history WHERE srvid = _srvid;
    DELETE FROM @extschema@.pg_reboot WHERE srvid = _srvid;
    DELETE FROM @extschema@.pg_track_version_history WHERE srvid = _srvid;
END;
$_$
LANGUAGE plpgsql;
