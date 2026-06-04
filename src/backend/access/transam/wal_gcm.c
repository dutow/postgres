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

static inline void
wal_gcm_build_aad(const char *xlog_header, XLogRecord *scratch)
{
	memcpy(scratch, xlog_header, SizeOfXLogRecord);
	scratch->xl_crc = 0;
	scratch->xl_prev = 0;
}

static inline EVP_CIPHER_CTX *
wal_gcm_get_ctx(EVP_CIPHER_CTX **slot)
{
#if WAL_GCM_CTX_MODE == 0
	if (*slot == NULL)
		*slot = EVP_CIPHER_CTX_new();
	if (*slot == NULL)
		elog(ERROR, "EVP_CIPHER_CTX_new failed");
	return *slot;
#else
	EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
	if (ctx == NULL)
		elog(ERROR, "EVP_CIPHER_CTX_new failed");
	(void) slot;
	return ctx;
#endif
}

static inline void
wal_gcm_release_ctx(EVP_CIPHER_CTX *ctx, EVP_CIPHER_CTX **slot)
{
#if WAL_GCM_CTX_MODE == 0
	(void) ctx;
	(void) slot;
#else
	(void) slot;
	EVP_CIPHER_CTX_free(ctx);
#endif
}

static inline void
wal_gcm_make_iv(unsigned char iv[WAL_GCM_IV_LEN])
{
#if WAL_GCM_IV_MODE == 0
	if (RAND_bytes(iv, WAL_GCM_IV_LEN) != 1)
		elog(ERROR, "RAND_bytes failed for WAL GCM IV");
#else
	uint32		pid = (uint32) MyProcPid;
	uint64		ctr = ++wal_gcm_iv_counter;

	memcpy(iv, &pid, 4);
	memcpy(iv + 4, &ctr, 8);
#endif
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
	EVP_CIPHER_CTX *ctx;
	unsigned char	iv[WAL_GCM_IV_LEN];
	XLogRecord		aad;
	int				outlen;

	WalGcmInit();

	wal_gcm_make_iv(iv);
	wal_gcm_build_aad(xlog_header, &aad);

	ctx = wal_gcm_get_ctx(&wal_gcm_enc_ctx);

	if (EVP_EncryptInit_ex2(ctx, EVP_aes_256_gcm(), WalGcmKey, iv, NULL) != 1)
		elog(ERROR, "EVP_EncryptInit_ex2 failed");

	if (EVP_EncryptUpdate(ctx, NULL, &outlen,
						  (const unsigned char *) &aad, SizeOfXLogRecord) != 1)
		elog(ERROR, "EVP_EncryptUpdate (AAD) failed");

	if (body_len > 0)
	{
		if (EVP_EncryptUpdate(ctx, (unsigned char *) cipher, &outlen,
							  (const unsigned char *) plain,
							  (int) body_len) != 1)
			elog(ERROR, "EVP_EncryptUpdate (body) failed");
	}

	if (EVP_EncryptFinal_ex(ctx, (unsigned char *) cipher, &outlen) != 1)
		elog(ERROR, "EVP_EncryptFinal_ex failed");

	if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, WAL_GCM_TAG_LEN,
							iv_tag_out + WAL_GCM_IV_LEN) != 1)
		elog(ERROR, "EVP_CTRL_GCM_GET_TAG failed");

	memcpy(iv_tag_out, iv, WAL_GCM_IV_LEN);

	wal_gcm_release_ctx(ctx, &wal_gcm_enc_ctx);
}

bool
WalGcmDecryptRecord(const char *xlog_header,
					char *cipher_in_plain_out,
					Size body_len,
					const char *iv,
					const char *tag)
{
	EVP_CIPHER_CTX *ctx;
	XLogRecord		aad;
	int				outlen;

	WalGcmInit();

	wal_gcm_build_aad(xlog_header, &aad);

	ctx = wal_gcm_get_ctx(&wal_gcm_dec_ctx);

	if (EVP_DecryptInit_ex2(ctx, EVP_aes_256_gcm(), WalGcmKey,
							(const unsigned char *) iv, NULL) != 1)
		elog(ERROR, "EVP_DecryptInit_ex2 failed");

	if (EVP_DecryptUpdate(ctx, NULL, &outlen,
						  (const unsigned char *) &aad, SizeOfXLogRecord) != 1)
		elog(ERROR, "EVP_DecryptUpdate (AAD) failed");

	if (body_len > 0)
	{
		if (EVP_DecryptUpdate(ctx,
							  (unsigned char *) cipher_in_plain_out, &outlen,
							  (const unsigned char *) cipher_in_plain_out,
							  (int) body_len) != 1)
			elog(ERROR, "EVP_DecryptUpdate (body) failed");
	}

	if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, WAL_GCM_TAG_LEN,
							(void *) tag) != 1)
		elog(ERROR, "EVP_CTRL_GCM_SET_TAG failed");

	if (EVP_DecryptFinal_ex(ctx, (unsigned char *) cipher_in_plain_out,
							&outlen) <= 0)
	{
		wal_gcm_release_ctx(ctx, &wal_gcm_dec_ctx);
		return false;
	}

	wal_gcm_release_ctx(ctx, &wal_gcm_dec_ctx);
	return true;
}
