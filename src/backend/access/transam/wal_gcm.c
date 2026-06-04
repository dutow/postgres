/*-------------------------------------------------------------------------
 *
 * wal_gcm.c
 *	  Direct OpenSSL EVP per-record WAL encryption.  Implementations
 *	  arrive in Phase 3 and Phase 4.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/wal_gcm.h"

void
WalGcmInit(void)
{
	/* Phase 3 */
}

void
WalGcmLogVariantAtStartup(void)
{
	/* Phase 3 */
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
