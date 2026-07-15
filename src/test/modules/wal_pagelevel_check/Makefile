# src/test/modules/wal_pagelevel_check/Makefile

TAP_TESTS = 1

# Requires a cluster built with the page-level CTR prototype,
# which is a compile-time choice, so skip during installcheck.
NO_INSTALLCHECK = 1

ifdef USE_PGXS
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
else
subdir = src/test/modules/wal_pagelevel_check
top_builddir = ../../../..
include $(top_builddir)/src/Makefile.global
include $(top_srcdir)/contrib/contrib-global.mk
endif
