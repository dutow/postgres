/*-------------------------------------------------------------------------
 *
 * wal_gcm_key.c
 *	  Hardcoded AES-256 key for the WAL GCM perf prototype.
 *
 * NEVER ship this.  Throwaway perf prototype only.
 *
 *-------------------------------------------------------------------------
 */
#ifndef FRONTEND
#include "postgres.h"
#else
#include "postgres_fe.h"
#endif

#include "common/wal_gcm.h"

const unsigned char WalGcmKey[WAL_GCM_KEY_LEN] = {
	0x6c, 0x73, 0x57, 0x4d, 0x4e, 0x42, 0x76, 0x74,
	0x42, 0x39, 0x68, 0x71, 0x59, 0x4a, 0x6f, 0x77,
	0x76, 0x73, 0x65, 0x6b, 0x53, 0x39, 0x6c, 0x6f,
	0x55, 0x77, 0x37, 0x44, 0x76, 0x66, 0x4c, 0x49,
};
