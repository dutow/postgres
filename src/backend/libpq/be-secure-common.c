/*-------------------------------------------------------------------------
 *
 * be-secure-common.c
 *
 * common implementation-independent SSL support code
 *
 * While be-secure.c contains the interfaces that the rest of the
 * communications code calls, this file contains support routines that are
 * used by the library-specific implementations such as be-secure-openssl.c.
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * IDENTIFICATION
 *	  src/backend/libpq/be-secure-common.c
 *
 *-------------------------------------------------------------------------
 */

#include "postgres.h"

#include <sys/stat.h>
#include <unistd.h>

#include "common/percentrepl.h"
#include "common/string.h"
#include "common/tomlc17.h"
#include "libpq/libpq.h"
#include "libpq/toml_config.h"
#include "storage/fd.h"
#include "utils/builtins.h"
#include "utils/guc.h"

static HostsLine *parse_hosts_line(TokenizedAuthLine *tok_line, int elevel);

/*
 * Run ssl_passphrase_command
 *
 * prompt will be substituted for %p.  is_server_start determines the loglevel
 * of error messages from executing the command, the loglevel for failures in
 * param substitution will be ERROR regardless of is_server_start.  The actual
 * command used depends on the configuration for the current host.
 *
 * The result will be put in buffer buf, which is of size size.  The return
 * value is the length of the actual result.
 */
int
run_ssl_passphrase_command(const char *cmd, const char *prompt,
						   bool is_server_start, char *buf, int size)
{
	int			loglevel = is_server_start ? ERROR : LOG;
	char	   *command;
	FILE	   *fh;
	int			pclose_rc;
	size_t		len = 0;

	Assert(prompt);
	Assert(size > 0);
	buf[0] = '\0';

	command = replace_percent_placeholders(cmd, "ssl_passphrase_command", "p", prompt);

	fh = OpenPipeStream(command, "r");
	if (fh == NULL)
	{
		ereport(loglevel,
				(errcode_for_file_access(),
				 errmsg("could not execute command \"%s\": %m",
						command)));
		goto error;
	}

	if (!fgets(buf, size, fh))
	{
		if (ferror(fh))
		{
			explicit_bzero(buf, size);
			ereport(loglevel,
					(errcode_for_file_access(),
					 errmsg("could not read from command \"%s\": %m",
							command)));
			goto error;
		}
	}

	pclose_rc = ClosePipeStream(fh);
	if (pclose_rc == -1)
	{
		explicit_bzero(buf, size);
		ereport(loglevel,
				(errcode_for_file_access(),
				 errmsg("could not close pipe to external command: %m")));
		goto error;
	}
	else if (pclose_rc != 0)
	{
		char	   *reason;

		explicit_bzero(buf, size);
		reason = wait_result_to_str(pclose_rc);
		ereport(loglevel,
				(errcode_for_file_access(),
				 errmsg("command \"%s\" failed",
						command),
				 errdetail_internal("%s", reason)));
		pfree(reason);
		goto error;
	}

	/* strip trailing newline and carriage return */
	len = pg_strip_crlf(buf);

error:
	pfree(command);
	return len;
}


/*
 * Check permissions for SSL key files.
 */
bool
check_ssl_key_file_permissions(const char *ssl_key_file, bool isServerStart)
{
	int			loglevel = isServerStart ? FATAL : LOG;
	struct stat buf;

	if (stat(ssl_key_file, &buf) != 0)
	{
		ereport(loglevel,
				(errcode_for_file_access(),
				 errmsg("could not access private key file \"%s\": %m",
						ssl_key_file)));
		return false;
	}

	/* Key file must be a regular file */
	if (!S_ISREG(buf.st_mode))
	{
		ereport(loglevel,
				(errcode(ERRCODE_CONFIG_FILE_ERROR),
				 errmsg("private key file \"%s\" is not a regular file",
						ssl_key_file)));
		return false;
	}

	/*
	 * Refuse to load key files owned by users other than us or root, and
	 * require no public access to the key file.  If the file is owned by us,
	 * require mode 0600 or less.  If owned by root, require 0640 or less to
	 * allow read access through either our gid or a supplementary gid that
	 * allows us to read system-wide certificates.
	 *
	 * Note that roughly similar checks are performed in
	 * src/interfaces/libpq/fe-secure-openssl.c so any changes here may need
	 * to be made there as well.  The environment is different though; this
	 * code can assume that we're not running as root.
	 *
	 * Ideally we would do similar permissions checks on Windows, but it is
	 * not clear how that would work since Unix-style permissions may not be
	 * available.
	 */
#if !defined(WIN32) && !defined(__CYGWIN__)
	if (buf.st_uid != geteuid() && buf.st_uid != 0)
	{
		ereport(loglevel,
				(errcode(ERRCODE_CONFIG_FILE_ERROR),
				 errmsg("private key file \"%s\" must be owned by the database user or root",
						ssl_key_file)));
		return false;
	}

	if ((buf.st_uid == geteuid() && buf.st_mode & (S_IRWXG | S_IRWXO)) ||
		(buf.st_uid == 0 && buf.st_mode & (S_IWGRP | S_IXGRP | S_IRWXO)))
	{
		ereport(loglevel,
				(errcode(ERRCODE_CONFIG_FILE_ERROR),
				 errmsg("private key file \"%s\" has group or world access",
						ssl_key_file),
				 errdetail("File must have permissions u=rw (0600) or less if owned by the database user, or permissions u=rw,g=r (0640) or less if owned by root.")));
		return false;
	}
#endif

	return true;
}

/*
 * parse_hosts_line
 *
 * Parses a loaded line from the pg_hosts.conf configuration and pulls out the
 * hostname, certificate, key and CA parts in order to build an SNI config in
 * the TLS backend. Validation of the parsed values is left for the TLS backend
 * to implement.
 */
static HostsLine *
parse_hosts_line(TokenizedAuthLine *tok_line, int elevel)
{
	HostsLine  *parsedline;
	List	   *tokens;
	ListCell   *field;
	AuthToken  *token;

	parsedline = palloc0(sizeof(HostsLine));
	parsedline->sourcefile = pstrdup(tok_line->file_name);
	parsedline->linenumber = tok_line->line_num;
	parsedline->rawline = pstrdup(tok_line->raw_line);
	parsedline->hostnames = NIL;

	/* Initialize optional fields */
	parsedline->ssl_passphrase_cmd = NULL;
	parsedline->ssl_passphrase_reload = false;

	/* Hostname */
	field = list_head(tok_line->fields);
	tokens = lfirst(field);
	foreach_ptr(AuthToken, hostname, tokens)
	{
		if ((tokens->length > 1) &&
			(strcmp(hostname->string, "*") == 0 || strcmp(hostname->string, "/no_sni/") == 0))
		{
			ereport(elevel,
					errcode(ERRCODE_CONFIG_FILE_ERROR),
					errmsg("default and non-SNI entries cannot be mixed with other entries"),
					errcontext("line %d of configuration file \"%s\"",
							   tok_line->line_num, tok_line->file_name));
			return NULL;
		}

		parsedline->hostnames = lappend(parsedline->hostnames, pstrdup(hostname->string));
	}

	/* SSL Certificate (Required) */
	field = lnext(tok_line->fields, field);
	if (!field)
	{
		ereport(elevel,
				errcode(ERRCODE_CONFIG_FILE_ERROR),
				errmsg("missing entry at end of line"),
				errcontext("line %d of configuration file \"%s\"",
						   tok_line->line_num, tok_line->file_name));
		return NULL;
	}
	tokens = lfirst(field);
	if (tokens->length > 1)
	{
		ereport(elevel,
				errcode(ERRCODE_CONFIG_FILE_ERROR),
				errmsg("multiple values specified for SSL certificate"),
				errcontext("line %d of configuration file \"%s\"",
						   tok_line->line_num, tok_line->file_name));
		return NULL;
	}
	token = linitial(tokens);
	parsedline->ssl_cert = pstrdup(token->string);

	/* SSL key (Required) */
	field = lnext(tok_line->fields, field);
	if (!field)
	{
		ereport(elevel,
				errcode(ERRCODE_CONFIG_FILE_ERROR),
				errmsg("missing entry at end of line"),
				errcontext("line %d of configuration file \"%s\"",
						   tok_line->line_num, tok_line->file_name));
		return NULL;
	}
	tokens = lfirst(field);
	if (tokens->length > 1)
	{
		ereport(elevel,
				errcode(ERRCODE_CONFIG_FILE_ERROR),
				errmsg("multiple values specified for SSL key"),
				errcontext("line %d of configuration file \"%s\"",
						   tok_line->line_num, tok_line->file_name));
		return NULL;
	}
	token = linitial(tokens);
	parsedline->ssl_key = pstrdup(token->string);

	/* SSL CA (optional) */
	field = lnext(tok_line->fields, field);
	if (!field)
		return parsedline;
	tokens = lfirst(field);
	if (tokens->length > 1)
	{
		ereport(elevel,
				errcode(ERRCODE_CONFIG_FILE_ERROR),
				errmsg("multiple values specified for SSL CA"),
				errcontext("line %d of configuration file \"%s\"",
						   tok_line->line_num, tok_line->file_name));
		return NULL;
	}
	token = linitial(tokens);
	parsedline->ssl_ca = pstrdup(token->string);

	/* SSL Passphrase Command (optional) */
	field = lnext(tok_line->fields, field);
	if (field)
	{
		tokens = lfirst(field);
		if (tokens->length > 1)
		{
			ereport(elevel,
					errcode(ERRCODE_CONFIG_FILE_ERROR),
					errmsg("multiple values specified for SSL passphrase command"),
					errcontext("line %d of configuration file \"%s\"",
							   tok_line->line_num, tok_line->file_name));
			return NULL;
		}
		token = linitial(tokens);
		parsedline->ssl_passphrase_cmd = pstrdup(token->string);

		/*
		 * SSL Passphrase Command support reload (optional). This field is
		 * only supported if there was a passphrase command parsed first, so
		 * nest it under the previous token.
		 */
		field = lnext(tok_line->fields, field);
		if (field)
		{
			tokens = lfirst(field);
			token = linitial(tokens);

			/*
			 * There should be no more tokens after this, if there are break
			 * parsing and report error to avoid silently accepting incorrect
			 * config.
			 */
			if (lnext(tok_line->fields, field))
			{
				ereport(elevel,
						errcode(ERRCODE_CONFIG_FILE_ERROR),
						errmsg("extra fields at end of line"),
						errcontext("line %d of configuration file \"%s\"",
								   tok_line->line_num, tok_line->file_name));
				return NULL;
			}

			if (tokens->length > 1 || !parse_bool(token->string, &parsedline->ssl_passphrase_reload))
			{
				ereport(elevel,
						errcode(ERRCODE_CONFIG_FILE_ERROR),
						errmsg("incorrect syntax for boolean value SSL_passphrase_cmd_reload"),
						errcontext("line %d of configuration file \"%s\"",
								   tok_line->line_num, tok_line->file_name));
				return NULL;
			}
		}
	}

	return parsedline;
}

static const char *const hosts_toml_keys[] = {
	"ssl_certificate",
	"ssl_key",
	"ssl_ca",
	"passphrase_command",
	"passphrase_command_reload",
	NULL,
};

/*
 * Validate one TOML table (a host entry or the _defaults table) and copy its
 * values into *out (a HostsLine); string values are pstrdup'd so they survive
 * freeing the parsed TOML document. "label" is the dotted path for
 * diagnostics, e.g. "hosts._defaults".
 *
 * *reload_present is set true if passphrase_command_reload was specified, so
 * the merge can tell "omitted" from "set to false".
 */
static bool
hosts_toml_collect(toml_datum_t tab, const char *label, const char *filename,
				   int elevel, HostsLine *out, bool *reload_present)
{
	toml_datum_t cert = toml_get(tab, "ssl_certificate");
	toml_datum_t key = toml_get(tab, "ssl_key");
	toml_datum_t ca = toml_get(tab, "ssl_ca");
	toml_datum_t cmd = toml_get(tab, "passphrase_command");
	toml_datum_t rel = toml_get(tab, "passphrase_command_reload");

	*reload_present = false;

	if (!toml_reject_unknown(hosts_toml_keys, tab, label, filename, elevel))
		return false;

	if (cert.type != TOML_UNKNOWN && cert.type != TOML_STRING)
		return toml_type_error(label, "ssl_certificate", "string", filename, elevel);
	if (key.type != TOML_UNKNOWN && key.type != TOML_STRING)
		return toml_type_error(label, "ssl_key", "string", filename, elevel);
	if (ca.type != TOML_UNKNOWN && ca.type != TOML_STRING)
		return toml_type_error(label, "ssl_ca", "string", filename, elevel);
	if (cmd.type != TOML_UNKNOWN && cmd.type != TOML_STRING)
		return toml_type_error(label, "passphrase_command", "string", filename, elevel);
	if (rel.type != TOML_UNKNOWN && rel.type != TOML_BOOLEAN)
		return toml_type_error(label, "passphrase_command_reload", "boolean", filename, elevel);

	if (cert.type == TOML_STRING)
		out->ssl_cert = pstrdup(cert.u.s);
	if (key.type == TOML_STRING)
		out->ssl_key = pstrdup(key.u.s);
	if (ca.type == TOML_STRING)
		out->ssl_ca = pstrdup(ca.u.s);
	if (cmd.type == TOML_STRING)
		out->ssl_passphrase_cmd = pstrdup(cmd.u.s);
	if (rel.type == TOML_BOOLEAN)
	{
		out->ssl_passphrase_reload = rel.u.boolean;
		*reload_present = true;
	}

	return true;
}

/*
 * Parse a pg_hosts TOML file into a list of HostsLine.
 *   *missing    = true  -> file does not exist (ENOENT); returns NIL
 *   *file_err  != NULL  -> whole-file open/parse error; returns NIL
 *   *had_errors = true  -> some entries were invalid; they were reported at
 *                          elevel and left out of the result
 */
static List *
parse_hosts_toml(const char *filename, int elevel,
				 bool *missing, bool *had_errors, char **file_err)
{
	toml_result_t result;
	toml_datum_t hosts_section;
	toml_datum_t defaults_dat;
	HostsLine	defaults = {0};
	bool		defaults_reload_present = false;
	bool		have_defaults = false;
	List	   *entries = NIL;

	*missing = false;
	*had_errors = false;
	*file_err = NULL;

	if (!toml_config_load(filename, elevel, &result, file_err))
	{
		if (*file_err == NULL)
			*missing = true;	/* ENOENT */
		return NIL;
	}

	hosts_section = toml_get(result.toptab, "hosts");
	if (hosts_section.type == TOML_UNKNOWN)
	{
		toml_free(result);
		return NIL;				/* no [hosts] table: empty */
	}
	if (hosts_section.type != TOML_TABLE)
	{
		*file_err = psprintf("\"hosts\" in \"%s\" is not a table", filename);
		ereport(elevel,
				(errcode(ERRCODE_CONFIG_FILE_ERROR),
				 errmsg("\"hosts\" in \"%s\" is not a table", filename)));
		toml_free(result);
		return NIL;
	}

	defaults_dat = toml_get(hosts_section, "_defaults");
	if (defaults_dat.type == TOML_TABLE)
	{
		if (hosts_toml_collect(defaults_dat, "hosts._defaults", filename,
							   elevel, &defaults, &defaults_reload_present))
			have_defaults = true;
		else
			*had_errors = true;
	}
	else if (defaults_dat.type != TOML_UNKNOWN)
	{
		ereport(elevel,
				(errcode(ERRCODE_CONFIG_FILE_ERROR),
				 errmsg("\"hosts._defaults\" in \"%s\" must be a table", filename)));
		*had_errors = true;
	}

	for (int i = 0; i < hosts_section.u.tab.size; i++)
	{
		const char *name = hosts_section.u.tab.key[i];
		toml_datum_t val = hosts_section.u.tab.value[i];
		HostsLine  *hl;
		bool		reload_present = false;

		if (strcmp(name, "_defaults") == 0)
			continue;

		if (val.type != TOML_TABLE)
		{
			ereport(elevel,
					(errcode(ERRCODE_CONFIG_FILE_ERROR),
					 errmsg("\"hosts.%s\" in \"%s\" must be a table", name, filename)));
			*had_errors = true;
			continue;
		}

		hl = palloc0_object(HostsLine);
		hl->linenumber = val.lineno;
		hl->sourcefile = pstrdup(filename);
		hl->rawline = pstrdup("");
		hl->hostnames = list_make1(pstrdup(name));

		{
			char	   *label = psprintf("hosts.%s", name);
			bool		ok = hosts_toml_collect(val, label, filename, elevel,
												hl, &reload_present);

			pfree(label);
			if (!ok)
			{
				*had_errors = true;
				continue;
			}
		}

		if (have_defaults)
		{
			if (hl->ssl_cert == NULL)
				hl->ssl_cert = defaults.ssl_cert;
			if (hl->ssl_key == NULL)
				hl->ssl_key = defaults.ssl_key;
			if (hl->ssl_ca == NULL)
				hl->ssl_ca = defaults.ssl_ca;
			if (hl->ssl_passphrase_cmd == NULL)
				hl->ssl_passphrase_cmd = defaults.ssl_passphrase_cmd;
			if (!reload_present && defaults_reload_present)
				hl->ssl_passphrase_reload = defaults.ssl_passphrase_reload;
		}

		if (hl->ssl_cert == NULL || hl->ssl_key == NULL)
		{
			ereport(elevel,
					(errcode(ERRCODE_CONFIG_FILE_ERROR),
					 errmsg("\"hosts.%s\" in \"%s\" is missing required \"ssl_certificate\" or \"ssl_key\"",
							name, filename)));
			*had_errors = true;
			continue;
		}

		entries = lappend(entries, hl);
	}

	toml_free(result);
	return entries;
}

/*
 * load_hosts
 *
 * Reads and parses the pg_hosts.conf configuration file and passes back a List
 * of HostsLine elements containing the parsed lines, or NIL in case of an empty
 * file.  The list is returned in the hosts parameter. The function will return
 * a HostsFileLoadResult value detailing the result of the operation.  When
 * the hosts configuration failed to load, the err_msg variable may have more
 * information in case it was passed as non-NULL.
 */
HostsFileLoadResult
load_hosts(List **hosts, char **err_msg)
{
	FILE	   *file;
	ListCell   *line;
	List	   *hosts_lines = NIL;
	List	   *parsed_lines = NIL;
	HostsLine  *newline;
	bool		ok = true;

	/*
	 * If we cannot return results then error out immediately. This implies
	 * API misuse or a similar kind of programmer error.
	 */
	if (!hosts)
	{
		if (err_msg)
			*err_msg = psprintf("cannot load config from \"%s\", return variable missing",
								HostsFileName);
		return HOSTSFILE_LOAD_FAILED;
	}
	*hosts = NIL;

	if (toml_path(HostsFileName))
	{
		bool		missing = false;
		bool		had_errors = false;
		char	   *file_err = NULL;
		List	   *entries;

		entries = parse_hosts_toml(HostsFileName, LOG, &missing, &had_errors,
								   &file_err);
		if (missing)
			return HOSTSFILE_MISSING;
		if (file_err)
		{
			if (err_msg)
				*err_msg = file_err;
			return HOSTSFILE_LOAD_FAILED;
		}

		*hosts = entries;

		if (had_errors)
		{
			if (err_msg)
				*err_msg = psprintf("loading config from \"%s\" failed due to parsing error",
									HostsFileName);
			return HOSTSFILE_LOAD_FAILED;
		}
		if (entries == NIL)
			return HOSTSFILE_EMPTY;
		return HOSTSFILE_LOAD_OK;
	}

	/*
	 * This is not an auth file per se, but it is using the same file format
	 * as the pg_hba and pg_ident files and thus the same code infrastructure.
	 * A future TODO might be to rename the supporting code with a more
	 * generic name?
	 */
	file = open_auth_file(HostsFileName, LOG, 0, err_msg);
	if (file == NULL)
	{
		if (errno == ENOENT)
			return HOSTSFILE_MISSING;

		return HOSTSFILE_LOAD_FAILED;
	}

	tokenize_auth_file(HostsFileName, file, &hosts_lines, LOG, 0);

	foreach(line, hosts_lines)
	{
		TokenizedAuthLine *tok_line = (TokenizedAuthLine *) lfirst(line);

		/*
		 * Mark processing as not-ok in case lines are found with errors in
		 * tokenization (.err_msg is set) or during parsing.
		 */
		if ((tok_line->err_msg != NULL) ||
			((newline = parse_hosts_line(tok_line, LOG)) == NULL))
		{
			ok = false;
			continue;
		}

		parsed_lines = lappend(parsed_lines, newline);
	}

	/* Free memory from tokenizer */
	free_auth_file(file, 0);
	*hosts = parsed_lines;

	if (!ok)
	{
		if (err_msg)
			*err_msg = psprintf("loading config from \"%s\" failed due to parsing error",
								HostsFileName);
		return HOSTSFILE_LOAD_FAILED;
	}

	if (parsed_lines == NIL)
		return HOSTSFILE_EMPTY;

	return HOSTSFILE_LOAD_OK;
}
