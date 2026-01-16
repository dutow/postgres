/*-------------------------------------------------------------------------
 *
 * OAuth utilities for frontend applications
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * src/fe_utils/oauth_utils.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres_fe.h"

#include "fe_utils/oauth_utils.h"
#include "libpq-fe.h"

/*
 * OAuth token hook for libpq
 *
 * If PGOAUTHTOKEN environment variable is set, provide its value as the
 * OAuth bearer token to skip the device authorization flow.
 */
static int
pg_oauth_token_hook(PGauthData type, PGconn *conn, void *data)
{
	PGoauthBearerRequest *req = data;
	const char *token;

	if (type != PQAUTHDATA_OAUTH_BEARER_TOKEN)
		return 0;

	token = getenv("PGOAUTHTOKEN");
	if (!token || token[0] == '\0')
		return 0;

	req->token = (char *) token;
	return 1;
}

/*
 * Register OAuth token hook
 */
void
pg_setup_oauth_hook(void)
{
	static bool hook_registered = false;

	if (!hook_registered && getenv("PGOAUTHTOKEN"))
	{
		PQsetAuthDataHook(pg_oauth_token_hook);
		hook_registered = true;
	}
}
