/*-------------------------------------------------------------------------
 *
 * wal_pagelevel_insert.c
 *	  Insert-time page-level WAL AES-256-CTR encryption prototype.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <openssl/evp.h>

#include "common/wal_pagelevel_insert.h"

#ifndef FRONTEND
#include "miscadmin.h"
#include "storage/ipc.h"
#endif

/*
 * Per-process lazy-allocated EVP contexts.  Backends preallocate via
 * WalPagelevelInsertEnsureCtx() at process init to avoid
 * EVP_CIPHER_CTX_new() inside a WAL-insert critical section.  Frontend
 * tools may either call EnsureCtx at startup or rely on the encrypt /
 * decrypt path to lazily allocate on first use (frontend has no
 * critical sections).
 */
static EVP_CIPHER_CTX *wal_pagelevel_insert_enc_ctx = NULL;
static EVP_CIPHER_CTX *wal_pagelevel_insert_dec_ctx = NULL;

#ifndef FRONTEND
static bool wal_pagelevel_insert_atexit_registered = false;

static void
wal_pagelevel_insert_atexit(int code, Datum arg)
{
	(void) code;
	(void) arg;

	if (wal_pagelevel_insert_enc_ctx)
	{
		EVP_CIPHER_CTX_free(wal_pagelevel_insert_enc_ctx);
		wal_pagelevel_insert_enc_ctx = NULL;
	}
	if (wal_pagelevel_insert_dec_ctx)
	{
		EVP_CIPHER_CTX_free(wal_pagelevel_insert_dec_ctx);
		wal_pagelevel_insert_dec_ctx = NULL;
	}
}
#endif

void
WalPagelevelInsertEnsureCtx(void)
{
#ifndef FRONTEND
	if (wal_pagelevel_insert_enc_ctx == NULL)
	{
		wal_pagelevel_insert_enc_ctx = EVP_CIPHER_CTX_new();
		if (wal_pagelevel_insert_enc_ctx == NULL)
			elog(ERROR, "EVP_CIPHER_CTX_new failed");
	}
	if (wal_pagelevel_insert_dec_ctx == NULL)
	{
		wal_pagelevel_insert_dec_ctx = EVP_CIPHER_CTX_new();
		if (wal_pagelevel_insert_dec_ctx == NULL)
			elog(ERROR, "EVP_CIPHER_CTX_new failed");
	}
	if (!wal_pagelevel_insert_atexit_registered)
	{
		before_shmem_exit(wal_pagelevel_insert_atexit, 0);
		wal_pagelevel_insert_atexit_registered = true;
	}
#endif
}

void
WalPagelevelInsertLogAtStartup(void)
{
}

void
WalPagelevelInsertEncrypt(char *dst, const char *src, Size len,
						  XLogRecPtr page_lsn, Size offset_in_page)
{
	(void) dst;
	(void) src;
	(void) len;
	(void) page_lsn;
	(void) offset_in_page;
}

void
WalPagelevelInsertDecrypt(char *buf, Size len,
						  XLogRecPtr page_lsn, Size offset_in_page)
{
	(void) buf;
	(void) len;
	(void) page_lsn;
	(void) offset_in_page;
}

void
WalPagelevelInsertKeystream(char *buf, XLogRecPtr page_lsn,
							Size offset_in_page, Size len)
{
	(void) buf;
	(void) page_lsn;
	(void) offset_in_page;
	(void) len;
}

void
WalPagelevelInsertEncryptRange(char *dst, const char *src, Size len,
							   XLogSegNo segno, Size start_off,
							   uint32 wal_segment_size)
{
	(void) dst;
	(void) src;
	(void) len;
	(void) segno;
	(void) start_off;
	(void) wal_segment_size;
}

void
WalPagelevelInsertDecryptRange(char *buf, Size len,
							   XLogSegNo segno, Size start_off,
							   uint32 wal_segment_size)
{
	(void) buf;
	(void) len;
	(void) segno;
	(void) start_off;
	(void) wal_segment_size;
}
