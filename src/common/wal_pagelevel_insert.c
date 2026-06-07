/*-------------------------------------------------------------------------
 *
 * wal_pagelevel_insert.c
 *	  Insert-time page-level WAL AES-256-CTR encryption prototype.
 *
 * Stub TU.  Phase 2 fills in the EVP context lifecycle; Phase 3 fills
 * in the crypto helpers.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "common/wal_pagelevel_insert.h"

void
WalPagelevelInsertEnsureCtx(void)
{
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
