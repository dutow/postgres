#include "postgres.h"

#include <openssl/evp.h>

#include "common/wal_pagelevel.h"

#ifndef FRONTEND
#include "access/xlog.h"			/* wal_segment_size */
#include "miscadmin.h"
#include "storage/ipc.h"
#include "utils/memutils.h"
#else
#include "common/logging.h"
#endif

#ifndef FRONTEND
#define WAL_PAGELEVEL_FAIL(msg) elog(ERROR, msg)
#else
#define WAL_PAGELEVEL_FAIL(msg) pg_fatal(msg)
#endif

/* Per-process lazy-allocated EVP contexts (backend + frontend). */
static EVP_CIPHER_CTX *wal_pagelevel_enc_ctx = NULL;
static EVP_CIPHER_CTX *wal_pagelevel_dec_ctx = NULL;

#ifndef FRONTEND
static MemoryContext wal_pagelevel_cxt = NULL;
static char	   *wal_pagelevel_cipher_buf = NULL;
static Size		wal_pagelevel_cipher_buf_size = 0;
static bool wal_pagelevel_atexit_registered = false;
#endif

#ifndef FRONTEND
static void
wal_pagelevel_atexit(int code, Datum arg)
{
	if (wal_pagelevel_enc_ctx)
	{
		EVP_CIPHER_CTX_free(wal_pagelevel_enc_ctx);
		wal_pagelevel_enc_ctx = NULL;
	}
	if (wal_pagelevel_dec_ctx)
	{
		EVP_CIPHER_CTX_free(wal_pagelevel_dec_ctx);
		wal_pagelevel_dec_ctx = NULL;
	}
	/* wal_pagelevel_cipher_buf lives in wal_pagelevel_cxt, freed by it. */
}
#endif

void
WalPagelevelInit(void)
{
#ifndef FRONTEND
	if (wal_pagelevel_cxt != NULL)
		return;					/* already done in this backend */

	wal_pagelevel_cxt = AllocSetContextCreate(TopMemoryContext,
											  "WAL pagelevel prototype",
											  ALLOCSET_DEFAULT_SIZES);
	MemoryContextAllowInCriticalSection(wal_pagelevel_cxt, true);

	if (!wal_pagelevel_atexit_registered)
	{
		before_shmem_exit(wal_pagelevel_atexit, 0);
		wal_pagelevel_atexit_registered = true;
	}
#endif
}

void
WalPagelevelLogAtStartup(void)
{
#ifndef FRONTEND
	ereport(LOG,
			(errmsg("WAL page-level encryption: AES-256-CTR, IV=page-start-LSN")));
#endif
}

/*
 * Build the AES-CTR initial counter block for the 16-byte block containing
 * (page_start_lsn + offset_in_page).
 *
 * IV layout:
 *   bytes 0..7:  page_start_lsn, big-endian
 *   bytes 8..15: zero
 *
 * Advanced by (offset_in_page / 16) blocks.  Any sub-block remainder
 * (offset_in_page % 16) is consumed by the caller's leading-discard update.
 */
static void
wal_pagelevel_build_iv(unsigned char iv[WAL_PAGELEVEL_IV_LEN],
					   XLogRecPtr page_start_lsn,
					   Size offset_in_page)
{
	uint64		blocks;
	int			i;
	uint64		carry;

	/* Big-endian LSN in bytes 0..7. */
	for (i = 0; i < 8; i++)
		iv[i] = (unsigned char) (page_start_lsn >> (56 - 8 * i));
	for (i = 8; i < 16; i++)
		iv[i] = 0;

	/* Advance by offset_in_page / 16 blocks via big-endian 128-bit add. */
	blocks = offset_in_page / WAL_PAGELEVEL_IV_LEN;
	carry = blocks;
	for (i = WAL_PAGELEVEL_IV_LEN - 1; i >= 0 && carry; i--)
	{
		uint64 sum = (uint64) iv[i] + (carry & 0xff);

		iv[i] = (unsigned char) (sum & 0xff);
		carry = (carry >> 8) + (sum >> 8);
	}
}

/*
 * Per-process EVP context for one direction.  Context allocation, cipher
 * fetch and the AES key schedule happen once per process here; per-range
 * calls only reset the IV, keeping the cached key schedule.
 */
static EVP_CIPHER_CTX *
wal_pagelevel_get_ctx(bool for_encrypt)
{
	EVP_CIPHER_CTX **ctxp;
	int			rc;

	ctxp = for_encrypt ? &wal_pagelevel_enc_ctx : &wal_pagelevel_dec_ctx;
	if (*ctxp != NULL)
		return *ctxp;

	*ctxp = EVP_CIPHER_CTX_new();
	if (*ctxp == NULL)
		WAL_PAGELEVEL_FAIL("EVP_CIPHER_CTX_new failed");

	if (for_encrypt)
		rc = EVP_EncryptInit_ex2(*ctxp, EVP_aes_256_ctr(),
								 WalPagelevelKey, NULL, NULL);
	else
		rc = EVP_DecryptInit_ex2(*ctxp, EVP_aes_256_ctr(),
								 WalPagelevelKey, NULL, NULL);
	if (rc != 1)
		WAL_PAGELEVEL_FAIL("EVP cipher init failed");

	return *ctxp;
}

/*
 * Shared encrypt/decrypt core.  dst may equal src (in place) or point to a
 * separate output buffer, fusing the copy into the cipher pass.
 *
 * No EVP_*Final_ex call: CTR is a stream cipher, Update produced every output
 * byte, and the context is re-initialized by the next call's IV-only init.
 */
static void
wal_pagelevel_cipher_range(bool for_encrypt, char *dst, const char *src,
						   Size len, XLogRecPtr page_start_lsn,
						   Size offset_in_page)
{
	unsigned char	iv[WAL_PAGELEVEL_IV_LEN];
	Size			leading_discard;
	Size			aligned_offset;
	int				outlen;
	EVP_CIPHER_CTX *ctx;
	int				rc;

	if (len == 0)
		return;

	Assert(offset_in_page + len <= XLOG_BLCKSZ);

	WalPagelevelInit();

	leading_discard = offset_in_page % WAL_PAGELEVEL_IV_LEN;
	aligned_offset = offset_in_page - leading_discard;

	wal_pagelevel_build_iv(iv, page_start_lsn, aligned_offset);

	ctx = wal_pagelevel_get_ctx(for_encrypt);

	/* IV-only re-init: NULL cipher and key keep the cached key schedule. */
	if (for_encrypt)
		rc = EVP_EncryptInit_ex2(ctx, NULL, NULL, iv, NULL);
	else
		rc = EVP_DecryptInit_ex2(ctx, NULL, NULL, iv, NULL);
	if (rc != 1)
		WAL_PAGELEVEL_FAIL("EVP IV init failed");

	/*
	 * If the start byte is mid-block, run leading_discard zero bytes through
	 * EVP_*Update to advance the CTR keystream position past them.  The output
	 * is thrown away; only the keystream advance matters.
	 */
	if (leading_discard > 0)
	{
		unsigned char discard_in[WAL_PAGELEVEL_IV_LEN] = {0};
		unsigned char discard_out[WAL_PAGELEVEL_IV_LEN];

		if (for_encrypt)
			rc = EVP_EncryptUpdate(ctx, discard_out, &outlen,
								   discard_in, (int) leading_discard);
		else
			rc = EVP_DecryptUpdate(ctx, discard_out, &outlen,
								   discard_in, (int) leading_discard);
		if (rc != 1)
			WAL_PAGELEVEL_FAIL("EVP discard update failed");
	}

	if (for_encrypt)
		rc = EVP_EncryptUpdate(ctx, (unsigned char *) dst, &outlen,
							   (const unsigned char *) src, (int) len);
	else
		rc = EVP_DecryptUpdate(ctx, (unsigned char *) dst, &outlen,
							   (const unsigned char *) src, (int) len);
	if (rc != 1 || outlen != (int) len)
		WAL_PAGELEVEL_FAIL("EVP update failed");
}

void
WalPagelevelEncryptRange(char *buf, Size len,
						 XLogRecPtr page_start_lsn,
						 Size offset_in_page)
{
	wal_pagelevel_cipher_range(true, buf, buf, len,
							   page_start_lsn, offset_in_page);
}

void
WalPagelevelDecryptRange(char *buf, Size len,
						 XLogRecPtr page_start_lsn,
						 Size offset_in_page)
{
	wal_pagelevel_cipher_range(false, buf, buf, len,
							   page_start_lsn, offset_in_page);
}

void
WalPagelevelEncryptPage(char *page, XLogRecPtr page_start_lsn)
{
	WalPagelevelEncryptRange(page, XLOG_BLCKSZ, page_start_lsn, 0);
}

void
WalPagelevelDecryptPage(char *page, XLogRecPtr page_start_lsn)
{
	WalPagelevelDecryptRange(page, XLOG_BLCKSZ, page_start_lsn, 0);
}

#ifndef FRONTEND
/*
 * Ensure the per-backend scratch ciphertext buffer is at least `need` bytes.
 * Grown high-water-mark.  Caller must have called WalPagelevelInit() first.
 */
static char *
wal_pagelevel_ensure_buf(Size need)
{
	MemoryContext old;

	if (wal_pagelevel_cipher_buf_size >= need)
		return wal_pagelevel_cipher_buf;

	old = MemoryContextSwitchTo(wal_pagelevel_cxt);
	if (wal_pagelevel_cipher_buf == NULL)
		wal_pagelevel_cipher_buf = palloc(need);
	else
		wal_pagelevel_cipher_buf = repalloc(wal_pagelevel_cipher_buf, need);
	wal_pagelevel_cipher_buf_size = need;
	MemoryContextSwitchTo(old);
	return wal_pagelevel_cipher_buf;
}

char *
WalPagelevelGetScratch(Size need)
{
	WalPagelevelInit();
	return wal_pagelevel_ensure_buf(need);
}

char *
WalPagelevelEncryptForWrite(const char *plain, Size len,
							XLogSegNo segno, Size seg_offset)
{
	char	   *scratch;
	Size		i;

	Assert((seg_offset % XLOG_BLCKSZ) == 0);
	Assert((len % XLOG_BLCKSZ) == 0);

	scratch = WalPagelevelGetScratch(len);

	/* Encrypt plaintext straight into scratch, no separate memcpy pass. */
	for (i = 0; i < len; i += XLOG_BLCKSZ)
	{
		XLogRecPtr page_start_lsn;

		page_start_lsn = (XLogRecPtr) segno * wal_segment_size +
						 seg_offset + i;
		wal_pagelevel_cipher_range(true, scratch + i, plain + i,
								   XLOG_BLCKSZ, page_start_lsn, 0);
	}

	return scratch;
}
#endif
