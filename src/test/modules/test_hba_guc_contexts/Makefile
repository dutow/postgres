# src/test/modules/test_hba_guc_contexts/Makefile

MODULE_big = test_hba_guc_contexts
OBJS = \
	$(WIN32RES) \
	test_hba_guc_contexts.o
PGFILEDESC = "test_hba_guc_contexts - test module for PGC_HBA context validation"

ifdef USE_PGXS
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
else
subdir = src/test/modules/test_hba_guc_contexts
top_builddir = ../../../..
include $(top_builddir)/src/Makefile.global
include $(top_srcdir)/contrib/contrib-global.mk
endif
