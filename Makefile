EXTENSION    = pg_track_settings
EXTVERSION   = $(shell grep default_version $(EXTENSION).control | sed -e "s/default_version[[:space:]]*=[[:space:]]*'\([^']*\)'/\1/")
TESTS        = $(wildcard test/sql/*.sql)
REGRESS      = $(patsubst test/sql/%.sql,%,$(TESTS))
REGRESS_OPTS = --inputdir=test
DOCS         = $(wildcard README.md)

DATA         = $(wildcard *--*.sql)

PG_CONFIG    = pg_config
PGXS         = $(shell $(PG_CONFIG) --pgxs)

include $(PGXS)


all:

release-zip: all
	git archive --format zip --prefix=${EXTENSION}-${EXTVERSION}/ --output ./${EXTENSION}-${EXTVERSION}.zip HEAD
	unzip ./${EXTENSION}-$(EXTVERSION).zip
	rm ./${EXTENSION}-$(EXTVERSION).zip
	rm ./${EXTENSION}-$(EXTVERSION)/.gitignore
	sed -i -e "s/__VERSION__/$(EXTVERSION)/g"  ./${EXTENSION}-$(EXTVERSION)/META.json
	zip -r ./${EXTENSION}-$(EXTVERSION).zip ./${EXTENSION}-$(EXTVERSION)/
	rm -rf ./${EXTENSION}-$(EXTVERSION)
