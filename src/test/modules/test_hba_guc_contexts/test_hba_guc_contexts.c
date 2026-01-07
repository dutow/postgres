/*-------------------------------------------------------------------------
 *
 * test_hba_guc_contexts.c
 *		Test module for validating PGC_HBA context restrictions
 *
 * This module defines GUC variables with different context levels to test
 * that only variables with context PGC_HBA or below can be set from pg_hba.conf.
 *
 * Copyright (c) 2026, PostgreSQL Global Development Group
 *
 * IDENTIFICATION
 *	  src/test/modules/test_hba_guc_contexts/test_hba_guc_contexts.c
 *
 *-------------------------------------------------------------------------
 */

#include "postgres.h"

#include "fmgr.h"
#include "utils/guc.h"

PG_MODULE_MAGIC;

static char *test_postmaster_var = NULL;
static char *test_sighup_var = NULL;
static char *test_su_backend_var = NULL;
static char *test_backend_var = NULL;
static char *test_suset_var = NULL;
static char *test_userset_var = NULL;

void
_PG_init(void)
{
	DefineCustomStringVariable("test_hba_guc_contexts.postmaster_var",
								"Test PGC_POSTMASTER variable",
								"This should NOT be settable from pg_hba.conf",
								&test_postmaster_var,
								"postmaster_default",
								PGC_POSTMASTER,
								0,
								NULL, NULL, NULL);

	DefineCustomStringVariable("test_hba_guc_contexts.sighup_var",
								"Test PGC_SIGHUP variable",
								"This should NOT be settable from pg_hba.conf",
								&test_sighup_var,
								"sighup_default",
								PGC_SIGHUP,
								0,
								NULL, NULL, NULL);

	DefineCustomStringVariable("test_hba_guc_contexts.su_backend_var",
								"Test PGC_SU_BACKEND variable",
								"This SHOULD be settable from pg_hba.conf",
								&test_su_backend_var,
								"su_backend_default",
								PGC_SU_BACKEND,
								0,
								NULL, NULL, NULL);

	DefineCustomStringVariable("test_hba_guc_contexts.backend_var",
								"Test PGC_BACKEND variable",
								"This SHOULD be settable from pg_hba.conf",
								&test_backend_var,
								"backend_default",
								PGC_BACKEND,
								0,
								NULL, NULL, NULL);

	DefineCustomStringVariable("test_hba_guc_contexts.suset_var",
								"Test PGC_SUSET variable",
								"This SHOULD be settable from pg_hba.conf",
								&test_suset_var,
								"suset_default",
								PGC_SUSET,
								0,
								NULL, NULL, NULL);

	DefineCustomStringVariable("test_hba_guc_contexts.userset_var",
								"Test PGC_USERSET variable",
								"This SHOULD be settable from pg_hba.conf",
								&test_userset_var,
								"userset_default",
								PGC_USERSET,
								0,
								NULL, NULL, NULL);

	MarkGUCPrefixReserved("test_hba_guc_contexts");
}
