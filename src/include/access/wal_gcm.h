/*-------------------------------------------------------------------------
 *
 * wal_gcm.h
 *	  Throwaway per-record WAL AES-256-GCM encryption prototype.
 *
 * Hardcoded key. No plugin API. No key management.  See
 * docs/plans/2026-06-04-wal-perrecord-gcm-prototype-design.md.
 *
 * Compile-time variants:
 *   WAL_GCM_IV_MODE   0 = RAND_bytes (default), 1 = counter+PID
 *   WAL_GCM_CTX_MODE  0 = reuse EVP ctx per backend (default),
 *                     1 = EVP_CIPHER_CTX_new/free per call
 *-------------------------------------------------------------------------
 */
#ifndef WAL_GCM_H
#define WAL_GCM_H

#include "access/xlogrecord.h"

#ifndef WAL_GCM_IV_MODE
#define WAL_GCM_IV_MODE 0
#endif

#ifndef WAL_GCM_CTX_MODE
#define WAL_GCM_CTX_MODE 0
#endif

#define WAL_GCM_KEY_LEN  32			/* AES-256 */
#define WAL_GCM_IV_LEN   12			/* standard GCM IV size */
#define WAL_GCM_TAG_LEN  16			/* GCM auth tag */
#define WAL_GCM_OVERHEAD (WAL_GCM_IV_LEN + WAL_GCM_TAG_LEN)	/* 28 */

extern const unsigned char WalGcmKey[WAL_GCM_KEY_LEN];

extern void WalGcmEncryptRecord(const char *xlog_header,
								const char *plain,
								char *cipher,
								Size body_len,
								char *iv_tag_out);

extern bool WalGcmDecryptRecord(const char *xlog_header,
								char *cipher_in_plain_out,
								Size body_len,
								const char *iv,
								const char *tag);

extern void WalGcmInit(void);
extern void WalGcmLogVariantAtStartup(void);

#endif							/* WAL_GCM_H */
