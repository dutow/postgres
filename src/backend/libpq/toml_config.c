/*-------------------------------------------------------------------------
 *
 * toml_config.c
 *	  Minimal loader for TOML configuration files.
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 *
 * IDENTIFICATION
 *	  src/backend/libpq/toml_config.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <errno.h>

#include "libpq/toml_config.h"
#include "storage/fd.h"

bool
toml_config_load(const char *filename, int elevel,
				 toml_result_t *result, char **err_msg)
{
	FILE	   *fp;

	if (err_msg)
		*err_msg = NULL;

	fp = AllocateFile(filename, "r");
	if (fp == NULL)
	{
		int			save_errno = errno;

		if (save_errno == ENOENT)
			return false;		/* "missing" - not an error */

		if (err_msg)
			*err_msg = psprintf("could not open TOML config file \"%s\": %m",
								filename);
		errno = save_errno;
		ereport(elevel,
				(errcode_for_file_access(),
				 errmsg("could not open TOML config file \"%s\": %m",
						filename)));
		return false;
	}

	*result = toml_parse_file(fp);
	FreeFile(fp);

	if (!result->ok)
	{
		if (err_msg)
			*err_msg = psprintf("TOML parse error in \"%s\": %s",
								filename, result->errmsg);
		ereport(elevel,
				(errcode(ERRCODE_CONFIG_FILE_ERROR),
				 errmsg("TOML parse error in \"%s\": %s",
						filename, result->errmsg)));
		toml_free(*result);
		return false;
	}

	return true;
}

/*
 * Reject keys of "tab" not in the NULL-terminated "allowed" list. "label" is
 * the dotted path for diagnostics (e.g. "hosts.foo"); each offender is logged
 * at LOG and *err_msg set to the last. Returns true if all keys known.
 */
bool
toml_reject_unknown(const char *const allowed[], toml_datum_t tab,
					const char *label, const char *filename, char **err_msg)
{
	bool		ok = true;

	for (int i = 0; i < tab.u.tab.size; i++)
	{
		const char *key = tab.u.tab.key[i];
		bool		known = false;

		for (int j = 0; allowed[j] != NULL; j++)
		{
			if (strcmp(key, allowed[j]) == 0)
			{
				known = true;
				break;
			}
		}
		if (known)
			continue;

		ereport(LOG,
				(errcode(ERRCODE_CONFIG_FILE_ERROR),
				 errmsg("\"%s.%s\" in \"%s\" is not a recognized key",
						label, key, filename)));
		if (err_msg)
			*err_msg = psprintf("\"%s.%s\" in \"%s\" is not a recognized key",
								label, key, filename);
		ok = false;
	}

	return ok;
}

/*
 * Report that "label.field" in "filename" must be of type "expected". Logs at
 * LOG, sets *err_msg, and returns false for use as a one-line bail-out.
 */
bool
toml_type_error(const char *label, const char *field, const char *expected,
				const char *filename, char **err_msg)
{
	ereport(LOG,
			(errcode(ERRCODE_CONFIG_FILE_ERROR),
			 errmsg("\"%s.%s\" in \"%s\" must be a %s",
					label, field, filename, expected)));
	if (err_msg)
		*err_msg = psprintf("\"%s.%s\" in \"%s\" must be a %s",
							label, field, filename, expected);
	return false;
}

/* True if "filename" names a TOML file (".toml" extension). */
bool
toml_path(const char *filename)
{
	const char *dot;

	if (filename == NULL)
		return false;
	dot = strrchr(filename, '.');
	return dot != NULL && strcmp(dot, ".toml") == 0;
}
