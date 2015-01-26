pg_track_settings
=================

pg_track_settings is a small extension that helps you keep track of
postgresql settings configuration.

It provides a function (**pg_track_settings_snapshot()**), that me must called
regularly. At each call, it will store the settings that have been changed
since last call. It will also track the postgresql start time if it's different
from the last one.


Usage
-----

- Create the extension in any database:

```
CREATE EXTENSION pg_track_settings;
```

Then make sure the **pg_track_settings_snapshot()** function called. Cron or
PoWA can be used for that.

Functions
---------

- `pg_track_settings_snapshot()`: collect the current settings value.
- `pg_track_setting(timestamptz)`: return all settings at the specified timestamp. Current time is used if no timestamped specified.
- `pg_track_setting_diff(timestamptz, timestamptz)`: return all settings that have changed between the two specified timestamps.

Example
-------
Call a first time the snapshot function to get the initial values:

```
postgres=# select pg_track_settings_snapshot()
 ----------------------------
  t
  (1 row)
```

A first snapshot is now taken:

```
 postgres=# select DISTINCT ts FROM pg_track_settings_history ;
              ts
-------------------------------
 2015-01-25 01:00:37.449846+01
 (1 row)
```

Let's assume the configuration changed, and reload the conf:

```
postgres=# select pg_reload_conf();
 pg_reload_conf
 ----------------
  t
  (1 row)
```

Call again the snapshot function:

```
postgres=# select * from pg_track_settings_snapshot();
 pg_track_settings_snapshot
----------------------------
 t
(1 row)
```

Now, we can check what settings changed:

```
postgres=# select * FROM pg_track_settings_diff(now() - interval '2 minutes', now());
        name         | from_setting | from_exists | to_setting | to_exists
---------------------+--------------|-------------|------------|----------
 checkpoint_segments | 30           | t           | 35         | t
(1 row)
```

We also have the history of postgres start time:

```
postgres=# SELECT * FROM pg_reboot;
              ts
-------------------------------
 2015-01-25 00:39:43.609195+01
(1 row)
```
