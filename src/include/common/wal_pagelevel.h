/*-------------------------------------------------------------------------
 *
 * wal_pagelevel.h
 *	  Throwaway page-level WAL AES-256-CTR encryption prototype.
 *
 * Hardcoded key.  No plugin API.  No key management.  No authentication.
 * In-memory WAL buffer stays plaintext; encryption happens only at the
 * disk-write boundary.  IV is the page-start LSN.
 *
 *-------------------------------------------------------------------------
 */
#ifndef WAL_PAGELEVEL_H
#define WAL_PAGELEVEL_H

#include "access/xlogdefs.h"

#define WAL_PAGELEVEL_KEY_LEN  32			/* AES-256 */
#define WAL_PAGELEVEL_IV_LEN   16			/* AES block size */

extern const unsigned char WalPagelevelKey[WAL_PAGELEVEL_KEY_LEN];

/*
 * Encrypt `len` bytes in place using AES-256-CTR.  The plaintext range
 * starts at byte offset `page_start_lsn + offset_in_page` of the WAL
 * stream; offset_in_page must be a multiple of 16 (page-aligned writes
 * are the only call pattern this prototype supports).
 *
 * page_start_lsn is the WAL LSN of byte 0 of the page containing the
 * range; the IV is derived from it directly.
 */
extern void WalPagelevelEncryptRange(char *buf,
									 Size len,
									 XLogRecPtr page_start_lsn,
									 Size offset_in_page);

/* Symmetric.  out-of-place not supported; decrypts in place. */
extern void WalPagelevelDecryptRange(char *buf,
									 Size len,
									 XLogRecPtr page_start_lsn,
									 Size offset_in_page);

/*
 * Convenience: encrypt/decrypt one full XLOG_BLCKSZ page in place.
 */
extern void WalPagelevelEncryptPage(char *page, XLogRecPtr page_start_lsn);
extern void WalPagelevelDecryptPage(char *page, XLogRecPtr page_start_lsn);

/* Lifecycle. */
extern void WalPagelevelInit(void);
extern void WalPagelevelLogAtStartup(void);

#ifndef FRONTEND
extern char *WalPagelevelGetScratch(Size need);
#endif

#ifndef FRONTEND
/*
 * Encrypt `len` bytes of WAL data starting at `seg_offset` within segment
 * `segno`, copying plaintext from `plain` into a per-backend scratch
 * ciphertext buffer.  Returns the scratch pointer; the caller pg_pwrite's
 * from there.  Caller must ensure seg_offset and seg_offset+len are both
 * XLOG_BLCKSZ-aligned (page-aligned writes only).
 */
extern char *WalPagelevelEncryptForWrite(const char *plain,
										 Size len,
										 XLogSegNo segno,
										 Size seg_offset);
#endif

#endif							/* WAL_PAGELEVEL_H */
