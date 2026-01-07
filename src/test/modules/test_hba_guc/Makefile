# src/test/modules/test_hba_guc/Makefile

MODULE_big = test_hba_guc
OBJS = \
	$(WIN32RES) \
	test_hba_guc.o
PGFILEDESC = "test_hba_guc - test module for PGC_HBA GUC variables"

EXTENSION = test_hba_guc
DATA = test_hba_guc--1.0.sql

ifdef USE_PGXS
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
else
subdir = src/test/modules/test_hba_guc
top_builddir = ../../../..
include $(top_builddir)/src/Makefile.global
include $(top_srcdir)/contrib/contrib-global.mk
endif
