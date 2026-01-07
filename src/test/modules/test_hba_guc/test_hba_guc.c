/*-------------------------------------------------------------------------
 *
 * test_hba_guc.c
 *		Test module for PGC_HBA GUC variables
 *
 * This module tests the PGC_HBA context level for GUC variables, which
 * allows variables to be set in pg_hba.conf or postgresql.conf but not
 * by client connections.
 *
 * Copyright (c) 2026, PostgreSQL Global Development Group
 *
 * IDENTIFICATION
 *	  src/test/modules/test_hba_guc/test_hba_guc.c
 *
 *-------------------------------------------------------------------------
 */

#include "postgres.h"

#include "fmgr.h"
#include "utils/builtins.h"
#include "utils/guc.h"

PG_MODULE_MAGIC;

static char *test_hba_string = NULL;
static int	test_hba_int = 0;
static bool test_hba_bool = false;

PG_FUNCTION_INFO_V1(get_test_hba_string);
PG_FUNCTION_INFO_V1(get_test_hba_int);
PG_FUNCTION_INFO_V1(get_test_hba_bool);

void
_PG_init(void)
{
	DefineCustomStringVariable("test_hba_guc.string_var",
							   "Test PGC_HBA string variable",
							   "This variable can only be set in pg_hba.conf or postgresql.conf",
							   &test_hba_string,
							   "default_value",
							   PGC_HBA,
							   0,
							   NULL,
							   NULL,
							   NULL);

	DefineCustomIntVariable("test_hba_guc.int_var",
							"Test PGC_HBA integer variable",
							"This variable can only be set in pg_hba.conf or postgresql.conf",
							&test_hba_int,
							42,
							0,
							10000,
							PGC_HBA,
							0,
							NULL,
							NULL,
							NULL);

	DefineCustomBoolVariable("test_hba_guc.bool_var",
							 "Test PGC_HBA boolean variable",
							 "This variable can only be set in pg_hba.conf or postgresql.conf",
							 &test_hba_bool,
							 false,
							 PGC_HBA,
							 0,
							 NULL,
							 NULL,
							 NULL);

	MarkGUCPrefixReserved("test_hba_guc");
}

Datum
get_test_hba_string(PG_FUNCTION_ARGS)
{
	if (test_hba_string == NULL)
		PG_RETURN_NULL();
	PG_RETURN_TEXT_P(cstring_to_text(test_hba_string));
}

Datum
get_test_hba_int(PG_FUNCTION_ARGS)
{
	PG_RETURN_INT32(test_hba_int);
}

Datum
get_test_hba_bool(PG_FUNCTION_ARGS)
{
	PG_RETURN_BOOL(test_hba_bool);
}
