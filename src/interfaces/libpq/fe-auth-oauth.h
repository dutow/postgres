/*-------------------------------------------------------------------------
 *
 * fe-auth-oauth.h
 *
 *	  Definitions for OAuth authentication implementations
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * src/interfaces/libpq/fe-auth-oauth.h
 *
 *-------------------------------------------------------------------------
 */

#ifndef FE_AUTH_OAUTH_H
#define FE_AUTH_OAUTH_H

#include "fe-auth-sasl.h"
#include "libpq-fe.h"


enum fe_oauth_step
{
	FE_OAUTH_INIT,
	FE_OAUTH_BEARER_SENT,
	FE_OAUTH_REQUESTING_TOKEN,
	FE_OAUTH_SERVER_ERROR,
};

/*
 * This struct is exported to the libpq-oauth module. If changes are needed
 * during backports to stable branches, please keep ABI compatibility (no
 * changes to existing members, add new members at the end, etc.).
 */
typedef struct
{
	enum fe_oauth_step step;

	PGconn	   *conn;
	void	   *async_ctx;

	void	   *builtin_flow;
} fe_oauth_state;

/*
 * Debug flags for PGOAUTHDEBUG environment variable.
 * Each flag controls a specific debug feature.
 */
typedef struct oauth_debug_flags
{
	/* UNSAFE features - require UNSAFE: prefix */
	bool		http;			/* allow HTTP (unencrypted) connections */
	bool		trace;			/* log HTTP traffic (exposes secrets) */
	bool		custom_ca;		/* allow custom CA certificate file */

	/* SAFE features - allowed without UNSAFE: prefix */
	bool		fast_retry;		/* allow zero-second retry intervals */
	bool		poll_counts;	/* print poll() statistics */
	bool		print_plugin_errors;	/* print plugin loading errors */
} oauth_debug_flags;

extern void pqClearOAuthToken(PGconn *conn);
extern oauth_debug_flags oauth_get_debug_flags(void);
extern bool use_builtin_flow(PGconn *conn, fe_oauth_state *state);

/* Mechanisms in fe-auth-oauth.c */
extern const pg_fe_sasl_mech pg_oauth_mech;

#endif							/* FE_AUTH_OAUTH_H */
