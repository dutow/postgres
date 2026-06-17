/*-------------------------------------------------------------------------
 *
 * toml_config.h
 *	  Minimal loader for TOML configuration files.
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 *
 * src/include/libpq/toml_config.h
 *
 *-------------------------------------------------------------------------
 */
#ifndef TOML_CONFIG_H
#define TOML_CONFIG_H

#include "common/tomlc17.h"

/*
 * Open and parse a TOML file.
 *
 *   return true              -> parsed; caller owns *result and must
 *                               toml_free(*result) when done
 *   return false, *err_msg==NULL -> file missing (ENOENT)
 *   return false, *err_msg!=NULL -> open/parse error (already ereport'd at
 *                               elevel); *err_msg holds the message
 */
extern bool toml_config_load(const char *filename, int elevel,
							 toml_result_t *result, char **err_msg);

/*
 * Reject keys of "tab" not in the NULL-terminated "allowed" list. Reports each
 * offender at LOG, sets *err_msg to the last. Returns true if all keys known.
 */
extern bool toml_reject_unknown(const char *const allowed[], toml_datum_t tab,
								const char *label, const char *filename,
								char **err_msg);

/*
 * Report that "label.field" in "filename" must be type "expected". Logs at LOG,
 * sets *err_msg, returns false.
 */
extern bool toml_type_error(const char *label, const char *field,
							const char *expected, const char *filename,
							char **err_msg);

/* True if "filename" names a TOML file (".toml" extension). */
extern bool toml_path(const char *filename);

#endif							/* TOML_CONFIG_H */
