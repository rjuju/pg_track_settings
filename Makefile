EXTENSION = pg_track_settings
DATA = pg_track_settings--1.0.sql

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
