/*-------------------------------------------------------------------------
 *
 * fe-auth-oauth-debug.c
 *	  Parsing logic for PGOAUTHDEBUG environment variable
 *
 * This file contains pure string parsing logic with no dependencies on
 * libpq or libpq-oauth implementation details. It's compiled into both
 * libraries to avoid code duplication.
 *
 * Portions Copyright (c) 1996-2025, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * IDENTIFICATION
 * 	src/interfaces/libpq/fe-auth-oauth-debug.c
 *
 *-------------------------------------------------------------------------
 */

#include "postgres_fe.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fe-auth-oauth.h"

/*
 * Parse a single debug option from PGOAUTHDEBUG.
 * Returns true if the option is recognized, false otherwise.
 * Sets *is_unsafe to indicate if this option requires the UNSAFE: prefix.
 */
static bool
parse_debug_option(const char *option, oauth_debug_flags *flags, bool *is_unsafe)
{
	*is_unsafe = false;

	/* Unsafe options */
	if (strcmp(option, "http") == 0)
	{
		flags->http = true;
		*is_unsafe = true;
		return true;
	}
	else if (strcmp(option, "trace") == 0)
	{
		flags->trace = true;
		*is_unsafe = true;
		return true;
	}
	else if (strcmp(option, "custom-ca") == 0)
	{
		flags->custom_ca = true;
		*is_unsafe = true;
		return true;
	}
	else if (strcmp(option, "issuer-mismatch") == 0)
	{
		flags->issuer_mismatch = true;
		*is_unsafe = true;
		return true;
	}
	/* Safe options */
	else if (strcmp(option, "fast-retry") == 0)
	{
		flags->fast_retry = true;
		return true;
	}
	else if (strcmp(option, "poll-counts") == 0)
	{
		flags->poll_counts = true;
		return true;
	}
	else if (strcmp(option, "print-plugin-errors") == 0)
	{
		flags->print_plugin_errors = true;
		return true;
	}

	return false;
}

/*
 * Parses the PGOAUTHDEBUG environment variable and returns debug flags.
 *
 * Supported formats:
 *   PGOAUTHDEBUG=UNSAFE              - legacy format, enables all features
 *   PGOAUTHDEBUG=option1,option2     - enable safe features only
 *   PGOAUTHDEBUG=UNSAFE:opt1,opt2    - enable unsafe and/or safe features
 *
 * Prints a warning and skips the invalid option if:
 * - An unrecognized option is specified
 * - An unsafe option is specified without the UNSAFE: prefix
 */
oauth_debug_flags
oauth_get_debug_flags(void)
{
	oauth_debug_flags flags = {0};
	const char *env = getenv("PGOAUTHDEBUG");
	char	   *options_str;
	char	   *option;
	char	   *saveptr = NULL;
	bool		unsafe_prefix = false;

	if (!env || env[0] == '\0')
		return flags;

	if (strcmp(env, "UNSAFE") == 0)
	{
		flags.http = true;
		flags.trace = true;
		flags.custom_ca = true;
		flags.issuer_mismatch = true;
		flags.fast_retry = true;
		flags.poll_counts = true;
		flags.print_plugin_errors = true;
		return flags;
	}

	if (strncmp(env, "UNSAFE:", 7) == 0)
	{
		unsafe_prefix = true;
		env += 7;
	}

	options_str = strdup(env);
	if (!options_str)
		return flags;

	option = strtok_r(options_str, ",", &saveptr);
	while (option != NULL)
	{
		bool		is_unsafe;

		if (!parse_debug_option(option, &flags, &is_unsafe))
		{
			fprintf(stderr,
					"WARNING: PGOAUTHDEBUG: unrecognized debug option \"%s\" (ignored)\n",
					option);
		}
		else if (is_unsafe && !unsafe_prefix)
		{
			fprintf(stderr,
					"WARNING: PGOAUTHDEBUG: unsafe option \"%s\" requires UNSAFE: prefix (ignored)\n"
					"Use: PGOAUTHDEBUG=UNSAFE:%s\n",
					option, option);
		}

		option = strtok_r(NULL, ",", &saveptr);
	}

	free(options_str);

	return flags;
}
