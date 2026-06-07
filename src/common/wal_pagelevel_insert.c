/*-------------------------------------------------------------------------
 *
 * wal_pagelevel_insert.c
 *	  Insert-time page-level WAL AES-256-CTR encryption prototype.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <openssl/evp.h>

#include "access/xlog_internal.h"
#include "common/wal_pagelevel_insert.h"

#ifndef FRONTEND
#include "miscadmin.h"
#include "storage/ipc.h"
#else
#include "common/logging.h"
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
#ifndef FRONTEND
	ereport(LOG,
			(errmsg("WAL page-level encryption (insert-time): AES-256-CTR, IV=page-start-LSN")));
#endif
}

/*
 * Build the AES-CTR initial counter block for a range starting at the
 * 16-byte block containing (page_lsn + offset_in_page).
 *
 * IV layout:
 *   bytes 0..7:  page_lsn, big-endian
 *   bytes 8..15: zero, then incremented by (offset_in_page / 16) blocks
 *
 * Any sub-block remainder (offset_in_page % 16) is handled by the caller
 * via the discard trick: running zero bytes through EVP_*Update to
 * advance OpenSSL's internal keystream position.
 */
static void
wal_pagelevel_insert_build_iv(unsigned char iv[WAL_PAGELEVEL_INSERT_IV_LEN],
							  XLogRecPtr page_lsn,
							  Size offset_in_page)
{
	uint64		blocks;
	int			i;
	uint64		carry;

	for (i = 0; i < 8; i++)
		iv[i] = (unsigned char) (page_lsn >> (56 - 8 * i));
	for (i = 8; i < 16; i++)
		iv[i] = 0;

	blocks = offset_in_page / WAL_PAGELEVEL_INSERT_IV_LEN;
	carry = blocks;
	for (i = WAL_PAGELEVEL_INSERT_IV_LEN - 1; i >= 0 && carry; i--)
	{
		uint64		sum = (uint64) iv[i] + (carry & 0xff);

		iv[i] = (unsigned char) (sum & 0xff);
		carry = (carry >> 8) + (sum >> 8);
	}
}

/*
 * Frontend-safe error reporting + lazy ctx alloc for frontend builds.
 */
#ifdef FRONTEND
static void
wal_pagelevel_insert_ensure_ctx_frontend(void)
{
	if (wal_pagelevel_insert_enc_ctx == NULL)
	{
		wal_pagelevel_insert_enc_ctx = EVP_CIPHER_CTX_new();
		if (wal_pagelevel_insert_enc_ctx == NULL)
			pg_fatal("EVP_CIPHER_CTX_new failed");
	}
	if (wal_pagelevel_insert_dec_ctx == NULL)
	{
		wal_pagelevel_insert_dec_ctx = EVP_CIPHER_CTX_new();
		if (wal_pagelevel_insert_dec_ctx == NULL)
			pg_fatal("EVP_CIPHER_CTX_new failed");
	}
}
#endif

void
WalPagelevelInsertEncrypt(char *dst, const char *src, Size len,
						  XLogRecPtr page_lsn, Size offset_in_page)
{
	unsigned char iv[WAL_PAGELEVEL_INSERT_IV_LEN];
	Size		leading_discard;
	Size		aligned_offset;
	int			outlen;

	if (len == 0)
		return;

	Assert(offset_in_page + len <= XLOG_BLCKSZ);

#ifdef FRONTEND
	wal_pagelevel_insert_ensure_ctx_frontend();
#else
	Assert(wal_pagelevel_insert_enc_ctx != NULL);
#endif

	leading_discard = offset_in_page % WAL_PAGELEVEL_INSERT_IV_LEN;
	aligned_offset = offset_in_page - leading_discard;

	wal_pagelevel_insert_build_iv(iv, page_lsn, aligned_offset);

	if (EVP_EncryptInit_ex2(wal_pagelevel_insert_enc_ctx, EVP_aes_256_ctr(),
							WalPagelevelInsertKey, iv, NULL) != 1)
#ifndef FRONTEND
		elog(ERROR, "EVP_EncryptInit_ex2 failed");
#else
		pg_fatal("EVP_EncryptInit_ex2 failed");
#endif

	if (leading_discard > 0)
	{
		unsigned char discard_in[WAL_PAGELEVEL_INSERT_IV_LEN] = {0};
		unsigned char discard_out[WAL_PAGELEVEL_INSERT_IV_LEN];

		if (EVP_EncryptUpdate(wal_pagelevel_insert_enc_ctx,
							  discard_out, &outlen,
							  discard_in, (int) leading_discard) != 1)
#ifndef FRONTEND
			elog(ERROR, "EVP_EncryptUpdate (discard) failed");
#else
			pg_fatal("EVP_EncryptUpdate (discard) failed");
#endif
	}

	if (EVP_EncryptUpdate(wal_pagelevel_insert_enc_ctx,
						  (unsigned char *) dst, &outlen,
						  (const unsigned char *) src, (int) len) != 1)
#ifndef FRONTEND
		elog(ERROR, "EVP_EncryptUpdate failed");
#else
		pg_fatal("EVP_EncryptUpdate failed");
#endif

	if (EVP_EncryptFinal_ex(wal_pagelevel_insert_enc_ctx,
							(unsigned char *) dst + outlen, &outlen) != 1)
#ifndef FRONTEND
		elog(ERROR, "EVP_EncryptFinal_ex failed");
#else
		pg_fatal("EVP_EncryptFinal_ex failed");
#endif
}

void
WalPagelevelInsertDecrypt(char *buf, Size len,
						  XLogRecPtr page_lsn, Size offset_in_page)
{
	unsigned char iv[WAL_PAGELEVEL_INSERT_IV_LEN];
	Size		leading_discard;
	Size		aligned_offset;
	int			outlen;

	if (len == 0)
		return;

	Assert(offset_in_page + len <= XLOG_BLCKSZ);

#ifdef FRONTEND
	wal_pagelevel_insert_ensure_ctx_frontend();
#else
	Assert(wal_pagelevel_insert_dec_ctx != NULL);
#endif

	leading_discard = offset_in_page % WAL_PAGELEVEL_INSERT_IV_LEN;
	aligned_offset = offset_in_page - leading_discard;

	wal_pagelevel_insert_build_iv(iv, page_lsn, aligned_offset);

	if (EVP_DecryptInit_ex2(wal_pagelevel_insert_dec_ctx, EVP_aes_256_ctr(),
							WalPagelevelInsertKey, iv, NULL) != 1)
#ifndef FRONTEND
		elog(ERROR, "EVP_DecryptInit_ex2 failed");
#else
		pg_fatal("EVP_DecryptInit_ex2 failed");
#endif

	if (leading_discard > 0)
	{
		unsigned char discard_in[WAL_PAGELEVEL_INSERT_IV_LEN] = {0};
		unsigned char discard_out[WAL_PAGELEVEL_INSERT_IV_LEN];

		if (EVP_DecryptUpdate(wal_pagelevel_insert_dec_ctx,
							  discard_out, &outlen,
							  discard_in, (int) leading_discard) != 1)
#ifndef FRONTEND
			elog(ERROR, "EVP_DecryptUpdate (discard) failed");
#else
			pg_fatal("EVP_DecryptUpdate (discard) failed");
#endif
	}

	if (EVP_DecryptUpdate(wal_pagelevel_insert_dec_ctx,
						  (unsigned char *) buf, &outlen,
						  (const unsigned char *) buf, (int) len) != 1)
#ifndef FRONTEND
		elog(ERROR, "EVP_DecryptUpdate failed");
#else
		pg_fatal("EVP_DecryptUpdate failed");
#endif

	if (EVP_DecryptFinal_ex(wal_pagelevel_insert_dec_ctx,
							(unsigned char *) buf + outlen, &outlen) != 1)
#ifndef FRONTEND
		elog(ERROR, "EVP_DecryptFinal_ex failed");
#else
		pg_fatal("EVP_DecryptFinal_ex failed");
#endif
}

void
WalPagelevelInsertKeystream(char *buf, XLogRecPtr page_lsn,
							Size offset_in_page, Size len)
{
	/*
	 * Encrypt all-zero plaintext: the result is raw keystream bytes,
	 * which is exactly what we want.  Use a small per-call zero buffer
	 * sized to one keystream chunk and loop to fill `len` bytes.
	 */
	static const char zeros[XLOG_BLCKSZ] = {0};
	Size		done = 0;

	while (done < len)
	{
		Size		chunk = Min(len - done, sizeof zeros);

		WalPagelevelInsertEncrypt(buf + done, zeros, chunk,
								  page_lsn, offset_in_page + done);
		done += chunk;
	}
}

/*
 * Helper: byte offset within a page where the header ends (= where
 * encrypted body starts).
 */
static inline uint32
wal_pagelevel_insert_header_size(XLogRecPtr page_lsn, uint32 wal_segment_size)
{
	return (XLogSegmentOffset(page_lsn, wal_segment_size) == 0)
		? SizeOfXLogLongPHD : SizeOfXLogShortPHD;
}

void
WalPagelevelInsertEncryptRange(char *dst, const char *src, Size len,
							   XLogSegNo segno, Size start_off,
							   uint32 wal_segment_size)
{
	Size		pos = 0;

	while (pos < len)
	{
		Size		abs_off = start_off + pos;
		Size		offset_in_page = abs_off % XLOG_BLCKSZ;
		Size		page_start_off = abs_off - offset_in_page;
		XLogRecPtr	page_lsn = (XLogRecPtr) segno * wal_segment_size + page_start_off;
		uint32		header_size = wal_pagelevel_insert_header_size(page_lsn, wal_segment_size);
		Size		page_remaining = XLOG_BLCKSZ - offset_in_page;
		Size		slice = Min(len - pos, page_remaining);

		if (offset_in_page < header_size)
		{
			Size		header_skip = Min(slice, header_size - offset_in_page);

			if (dst + pos != src + pos)
				memcpy(dst + pos, src + pos, header_skip);
			pos += header_skip;
			continue;
		}

		WalPagelevelInsertEncrypt(dst + pos, src + pos, slice,
								  page_lsn, offset_in_page);
		pos += slice;
	}
}

void
WalPagelevelInsertDecryptRange(char *buf, Size len,
							   XLogSegNo segno, Size start_off,
							   uint32 wal_segment_size)
{
	Size		pos = 0;

	while (pos < len)
	{
		Size		abs_off = start_off + pos;
		Size		offset_in_page = abs_off % XLOG_BLCKSZ;
		Size		page_start_off = abs_off - offset_in_page;
		XLogRecPtr	page_lsn = (XLogRecPtr) segno * wal_segment_size + page_start_off;
		uint32		header_size = wal_pagelevel_insert_header_size(page_lsn, wal_segment_size);
		Size		page_remaining = XLOG_BLCKSZ - offset_in_page;
		Size		slice = Min(len - pos, page_remaining);

		if (offset_in_page < header_size)
		{
			Size		header_skip = Min(slice, header_size - offset_in_page);

			pos += header_skip;
			continue;
		}

		WalPagelevelInsertDecrypt(buf + pos, slice,
								  page_lsn, offset_in_page);
		pos += slice;
	}
}
