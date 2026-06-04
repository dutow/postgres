/*-------------------------------------------------------------------------
 *
 * wal_gcm.c
 *	  Direct OpenSSL EVP per-record WAL encryption.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <openssl/evp.h>
#include <openssl/rand.h>

#include "access/wal_gcm.h"
#include "miscadmin.h"
#include "storage/ipc.h"
#include "utils/memutils.h"

/* Per-backend lazy-allocated state.  Only touched by WAL hot paths. */
static EVP_CIPHER_CTX *wal_gcm_enc_ctx = NULL;
static EVP_CIPHER_CTX *wal_gcm_dec_ctx = NULL;
static MemoryContext   wal_gcm_cxt = NULL;
static bool            wal_gcm_atexit_registered = false;

#if WAL_GCM_IV_MODE == 1
static uint64 wal_gcm_iv_counter = 0;
#endif

static void
wal_gcm_atexit(int code, Datum arg)
{
	if (wal_gcm_enc_ctx)
	{
		EVP_CIPHER_CTX_free(wal_gcm_enc_ctx);
		wal_gcm_enc_ctx = NULL;
	}
	if (wal_gcm_dec_ctx)
	{
		EVP_CIPHER_CTX_free(wal_gcm_dec_ctx);
		wal_gcm_dec_ctx = NULL;
	}
	/* wal_gcm_cxt is in TopMemoryContext and freed by it. */
}

void
WalGcmInit(void)
{
	if (wal_gcm_cxt != NULL)
		return;					/* already done in this backend */

	wal_gcm_cxt = AllocSetContextCreate(TopMemoryContext,
										"WAL GCM prototype",
										ALLOCSET_DEFAULT_SIZES);
	MemoryContextAllowInCriticalSection(wal_gcm_cxt, true);

	if (!wal_gcm_atexit_registered)
	{
		before_shmem_exit(wal_gcm_atexit, 0);
		wal_gcm_atexit_registered = true;
	}
}

void
WalGcmLogVariantAtStartup(void)
{
	const char *iv_mode =
#if WAL_GCM_IV_MODE == 0
		"RAND_bytes";
#elif WAL_GCM_IV_MODE == 1
		"counter+PID";
#else
		"unknown";
#endif

	const char *ctx_mode =
#if WAL_GCM_CTX_MODE == 0
		"reuse";
#elif WAL_GCM_CTX_MODE == 1
		"per-call";
#else
		"unknown";
#endif

	ereport(LOG,
			(errmsg("WAL GCM prototype: AES-256-GCM, IV=%s, CTX=%s",
					iv_mode, ctx_mode)));
}

void
WalGcmEncryptRecord(const char *xlog_header,
					const char *plain,
					char *cipher,
					Size body_len,
					char *iv_tag_out)
{
	elog(ERROR, "WalGcmEncryptRecord not implemented yet");
}

bool
WalGcmDecryptRecord(const char *xlog_header,
					char *cipher_in_plain_out,
					Size body_len,
					const char *iv,
					const char *tag)
{
	elog(ERROR, "WalGcmDecryptRecord not implemented yet");
	return false;
}
