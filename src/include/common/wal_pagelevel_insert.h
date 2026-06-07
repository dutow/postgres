/*-------------------------------------------------------------------------
 *
 * wal_pagelevel_insert.h
 *	  Throwaway page-level WAL AES-256-CTR encryption prototype,
 *	  insert-time variant.
 *
 * Hardcoded key.  No plugin API.  No key management.  No authentication.
 * Page header stays plaintext; page body is encrypted in shared memory
 * at WAL-insert time.  IV is the page-start LSN.
 *
 * See docs/plans/2026-06-07-wal-pagelevel-ctr-insert-prototype-design.md.
 *
 *-------------------------------------------------------------------------
 */
#ifndef WAL_PAGELEVEL_INSERT_H
#define WAL_PAGELEVEL_INSERT_H

#include "access/xlogdefs.h"

#define WAL_PAGELEVEL_INSERT_KEY_LEN	32	/* AES-256 */
#define WAL_PAGELEVEL_INSERT_IV_LEN		16	/* AES block size */

extern const unsigned char WalPagelevelInsertKey[WAL_PAGELEVEL_INSERT_KEY_LEN];

/* Lifecycle. */
extern void WalPagelevelInsertEnsureCtx(void);
extern void WalPagelevelInsertLogAtStartup(void);

/*
 * Encrypt `len` bytes from `src` into `dst` (in-place permitted when
 * dst == src).  `page_lsn` is the LSN of byte 0 of the page containing
 * the range; `offset_in_page` is the absolute byte offset within that
 * page where the range begins.  Caller is responsible for ensuring
 * `offset_in_page + len <= XLOG_BLCKSZ`.
 */
extern void WalPagelevelInsertEncrypt(char *dst, const char *src, Size len,
									  XLogRecPtr page_lsn,
									  Size offset_in_page);

/* Symmetric in-place decrypt. */
extern void WalPagelevelInsertDecrypt(char *buf, Size len,
									  XLogRecPtr page_lsn,
									  Size offset_in_page);

/*
 * Write `len` bytes of raw CTR keystream into `buf` (equivalent to
 * encrypting all-zero plaintext under the page IV at the given offset).
 * Used by AdvanceXLInsertBuffer to encrypt the post-MemSet zero body.
 */
extern void WalPagelevelInsertKeystream(char *buf,
										XLogRecPtr page_lsn,
										Size offset_in_page,
										Size len);

/*
 * Walk per-page slices over [segno * wal_segment_size + start_off,
 * + len) and encrypt body portions only (skipping header bytes for
 * any page boundary the range crosses).  For walreceiver,
 * pg_receivewal, pg_basebackup stream, pg_resetwal, BootStrapXLOG.
 *
 * Header bytes within the range are memcpy'd verbatim (plaintext on
 * disk).  In-place permitted when dst == src.
 */
extern void WalPagelevelInsertEncryptRange(char *dst, const char *src,
										   Size len,
										   XLogSegNo segno,
										   Size start_off,
										   uint32 wal_segment_size);

/*
 * Symmetric in-place decrypt walker; skips header bytes the same way.
 * For WALRead / WALReadFromBuffers / XLogPageRead callers spanning
 * page boundaries.
 */
extern void WalPagelevelInsertDecryptRange(char *buf, Size len,
										   XLogSegNo segno,
										   Size start_off,
										   uint32 wal_segment_size);

#endif							/* WAL_PAGELEVEL_INSERT_H */
