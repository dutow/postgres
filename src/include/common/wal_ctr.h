/*-------------------------------------------------------------------------
 *
 * wal_ctr.h
 *	  Throwaway per-record WAL AES-256-CTR encryption prototype.
 *
 * Per-record IVs are drawn from a per-backend counter: one RAND_bytes seed
 * per backend, advanced by the number of 16-byte blocks each record
 * consumes.  The starting counter block is stored on disk with the record,
 * so every record decrypts independently.
 *-------------------------------------------------------------------------
 */
#ifndef WAL_CTR_H
#define WAL_CTR_H

#include "access/xlogrecord.h"

#define WAL_CTR_KEY_LEN  32			/* AES-256 */
#define WAL_CTR_IV_LEN   16			/* AES block size */
#define WAL_CTR_OVERHEAD WAL_CTR_IV_LEN

extern const unsigned char WalCtrKey[WAL_CTR_KEY_LEN];

/*
 * Streaming encrypt API.  WalCtrEncryptBegin() captures the IV / counter
 * block for the record into `iv_out` and resets the (key-loaded) EVP context
 * to that IV.  WalCtrEncryptUpdate() may be called any number of times to
 * encrypt consecutive body segments (in == out is allowed); the CTR keystream
 * advances across calls.  WalCtrEncryptFinal() closes the record and advances
 * the per-backend counter past the keystream just consumed.
 */
extern void WalCtrEncryptBegin(char *iv_out);
extern void WalCtrEncryptUpdate(const char *in, char *out, Size len);
extern void WalCtrEncryptFinal(void);

/*
 * Convenience wrapper for callers with a single contiguous body buffer
 * (in == out allowed).  Equivalent to Begin + one Update + Final.  Caller is
 * responsible for skipping the call when body_len == 0.
 */
extern void WalCtrEncryptRecord(const char *plain,
								char *cipher,
								Size body_len,
								char *iv_out);

/*
 * Decrypt `body_len` ciphertext bytes in place (out == in allowed) using the
 * 16-byte `iv` as the AES-CTR initial counter block.
 */
extern void WalCtrDecryptRecord(char *cipher_in_plain_out,
								Size body_len,
								const char *iv);

/*
 * Lifecycle.  WalCtrInit() is idempotent; safe to call from every WAL hot
 * path.  An internal atexit handler is registered via before_shmem_exit
 * on first init to free per-backend EVP contexts at shutdown.
 */
extern void WalCtrInit(void);
extern void WalCtrLogVariantAtStartup(void);

#endif							/* WAL_CTR_H */
