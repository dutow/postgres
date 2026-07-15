/*-------------------------------------------------------------------------
 *
 * wal_ctr.c
 *	  Direct OpenSSL EVP per-record WAL encryption (AES-256-CTR).
 *
 *	  The AES key is loaded into the EVP contexts once per backend; the
 *	  per-record hot path only resets the IV, so the key schedule is never
 *	  rebuilt.  Per-record IVs come from a per-backend counter seeded once
 *	  with RAND_bytes and advanced by the number of 16-byte blocks each
 *	  record consumes, avoiding a CSPRNG draw per record.
 *
 * IDENTIFICATION
 *	  src/common/wal_ctr.c
 *
 *-------------------------------------------------------------------------
 */

#ifndef FRONTEND
#include "postgres.h"
#else
#include "postgres_fe.h"
#endif

#include <openssl/evp.h>
#include <openssl/rand.h>

#include "common/wal_ctr.h"

#ifndef FRONTEND
#include "miscadmin.h"
#include "storage/ipc.h"
#include "utils/memutils.h"
#else
#include "common/logging.h"
#endif

#ifndef FRONTEND
#define WAL_CTR_FATAL(...) elog(ERROR, __VA_ARGS__)
#else
#define WAL_CTR_FATAL(...) pg_fatal(__VA_ARGS__)
#endif

/* Per-backend lazy-allocated state.  Only touched by WAL hot paths. */
static EVP_CIPHER_CTX *wal_ctr_enc_ctx = NULL;
static EVP_CIPHER_CTX *wal_ctr_dec_ctx = NULL;

/* Per-backend IV counter: seeded once, advanced per record. */
static unsigned char wal_ctr_counter[WAL_CTR_IV_LEN];
static bool			 wal_ctr_counter_seeded = false;
static Size			 wal_ctr_enc_bytes = 0;	/* body bytes in current record */

#ifndef FRONTEND
static bool wal_ctr_atexit_registered = false;
#endif

/*
 * Big-endian 128-bit counter add.  Advances wal_ctr_counter past the
 * keystream a record consumed.  Matches the increment scheme that OpenSSL's
 * EVP_aes_256_ctr() uses on its 16-byte IV.
 */
static inline void
wal_ctr_counter_add(unsigned char ctr[WAL_CTR_IV_LEN], uint64 nblocks)
{
	int		i;
	uint64	carry = nblocks;

	for (i = WAL_CTR_IV_LEN - 1; i >= 0 && carry; i--)
	{
		uint64 sum = (uint64) ctr[i] + (carry & 0xff);

		ctr[i] = (unsigned char) (sum & 0xff);
		carry = (carry >> 8) + (sum >> 8);
	}
}

#ifndef FRONTEND
static void
wal_ctr_atexit(int code, Datum arg)
{
	if (wal_ctr_enc_ctx)
	{
		EVP_CIPHER_CTX_free(wal_ctr_enc_ctx);
		wal_ctr_enc_ctx = NULL;
	}
	if (wal_ctr_dec_ctx)
	{
		EVP_CIPHER_CTX_free(wal_ctr_dec_ctx);
		wal_ctr_dec_ctx = NULL;
	}
	wal_ctr_counter_seeded = false;
}
#endif

/*
 * Allocate both EVP contexts and load the AES key once.  Idempotent and safe
 * to call from every WAL hot path.  Loading the key here (with a NULL IV)
 * means the per-record Begin/Decrypt calls only reset the IV and never rerun
 * the AES-256 key schedule.
 */
void
WalCtrInit(void)
{
	if (wal_ctr_enc_ctx == NULL)
	{
		wal_ctr_enc_ctx = EVP_CIPHER_CTX_new();
		if (wal_ctr_enc_ctx == NULL)
			WAL_CTR_FATAL("EVP_CIPHER_CTX_new failed");
		if (EVP_EncryptInit_ex2(wal_ctr_enc_ctx, EVP_aes_256_ctr(),
								WalCtrKey, NULL, NULL) != 1)
			WAL_CTR_FATAL("EVP_EncryptInit_ex2 failed (key load)");
	}

	if (wal_ctr_dec_ctx == NULL)
	{
		wal_ctr_dec_ctx = EVP_CIPHER_CTX_new();
		if (wal_ctr_dec_ctx == NULL)
			WAL_CTR_FATAL("EVP_CIPHER_CTX_new failed");
		if (EVP_DecryptInit_ex2(wal_ctr_dec_ctx, EVP_aes_256_ctr(),
								WalCtrKey, NULL, NULL) != 1)
			WAL_CTR_FATAL("EVP_DecryptInit_ex2 failed (key load)");
	}

#ifndef FRONTEND
	if (!wal_ctr_atexit_registered)
	{
		before_shmem_exit(wal_ctr_atexit, 0);
		wal_ctr_atexit_registered = true;
	}
#endif
}

void
WalCtrLogVariantAtStartup(void)
{
#ifndef FRONTEND
	ereport(LOG,
			(errmsg("WAL CTR prototype: AES-256-CTR, per-record counter IV")));
#endif
}

void
WalCtrEncryptBegin(char *iv_out)
{
	WalCtrInit();

	if (!wal_ctr_counter_seeded)
	{
		if (RAND_bytes(wal_ctr_counter, WAL_CTR_IV_LEN) != 1)
			WAL_CTR_FATAL("RAND_bytes failed for WAL CTR seed");
		wal_ctr_counter_seeded = true;
	}

	/* Record the starting counter block; decrypt is self-contained from it. */
	memcpy(iv_out, wal_ctr_counter, WAL_CTR_IV_LEN);

	/* IV-only reset: key stays loaded, no AES key schedule rebuild. */
	if (EVP_EncryptInit_ex2(wal_ctr_enc_ctx, NULL, NULL,
							wal_ctr_counter, NULL) != 1)
		WAL_CTR_FATAL("EVP_EncryptInit_ex2 failed (iv reset)");

	wal_ctr_enc_bytes = 0;
}

void
WalCtrEncryptUpdate(const char *in, char *out, Size len)
{
	int		outlen;

	if (len == 0)
		return;

	if (EVP_EncryptUpdate(wal_ctr_enc_ctx,
						  (unsigned char *) out, &outlen,
						  (const unsigned char *) in, (int) len) != 1)
		WAL_CTR_FATAL("EVP_EncryptUpdate failed");

	wal_ctr_enc_bytes += len;
}

void
WalCtrEncryptFinal(void)
{
	unsigned char	tmp[WAL_CTR_IV_LEN];
	int				outlen;

	/* CTR produces no trailing bytes, but the API requires the call. */
	if (EVP_EncryptFinal_ex(wal_ctr_enc_ctx, tmp, &outlen) != 1)
		WAL_CTR_FATAL("EVP_EncryptFinal_ex failed");

	/* Advance the counter past every 16-byte block this record consumed. */
	wal_ctr_counter_add(wal_ctr_counter, (wal_ctr_enc_bytes + 15) / 16);
}

void
WalCtrEncryptRecord(const char *plain,
					char *cipher,
					Size body_len,
					char *iv_out)
{
	Assert(body_len > 0);

	WalCtrEncryptBegin(iv_out);
	WalCtrEncryptUpdate(plain, cipher, body_len);
	WalCtrEncryptFinal();
}

void
WalCtrDecryptRecord(char *cipher_in_plain_out,
					Size body_len,
					const char *iv)
{
	int		outlen;

	WalCtrInit();

	/* IV-only reset: key stays loaded, no AES key schedule rebuild. */
	if (EVP_DecryptInit_ex2(wal_ctr_dec_ctx, NULL, NULL,
							(const unsigned char *) iv, NULL) != 1)
		WAL_CTR_FATAL("EVP_DecryptInit_ex2 failed");

	if (EVP_DecryptUpdate(wal_ctr_dec_ctx,
						  (unsigned char *) cipher_in_plain_out, &outlen,
						  (const unsigned char *) cipher_in_plain_out,
						  (int) body_len) != 1)
		WAL_CTR_FATAL("EVP_DecryptUpdate failed");

	if (EVP_DecryptFinal_ex(wal_ctr_dec_ctx,
							(unsigned char *) cipher_in_plain_out + outlen,
							&outlen) != 1)
		WAL_CTR_FATAL("EVP_DecryptFinal_ex failed");
}
