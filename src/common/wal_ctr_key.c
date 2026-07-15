/*-------------------------------------------------------------------------
 *
 * wal_ctr_key.c
 *	  Hardcoded AES-256 key for the WAL CTR perf prototype.
 *
 * NEVER ship this.  Throwaway perf prototype only.
 *
 * IDENTIFICATION
 *	  src/common/wal_ctr_key.c
 *
 *-------------------------------------------------------------------------
 */

#ifndef FRONTEND
#include "postgres.h"
#else
#include "postgres_fe.h"
#endif

#include "common/wal_ctr.h"

const unsigned char WalCtrKey[WAL_CTR_KEY_LEN] = {
	0x43, 0x54, 0x52, 0x77, 0x61, 0x6c, 0x70, 0x72,
	0x6f, 0x74, 0x6f, 0x74, 0x79, 0x70, 0x65, 0x6b,
	0x65, 0x79, 0x6e, 0x6f, 0x74, 0x66, 0x6f, 0x72,
	0x70, 0x72, 0x6f, 0x64, 0x75, 0x73, 0x65, 0x21,
};
