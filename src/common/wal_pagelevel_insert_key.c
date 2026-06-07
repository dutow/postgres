/*-------------------------------------------------------------------------
 *
 * wal_pagelevel_insert_key.c
 *	  Hardcoded AES-256 key for the insert-time page-level WAL CTR
 *	  perf prototype.
 *
 * NEVER ship this.  Throwaway perf prototype only.  Distinct value from
 * the sibling wal_pagelevel_key.c so a binary built against the wrong
 * variant fails decrypt loudly rather than silently producing garbage.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"
#include "common/wal_pagelevel_insert.h"

const unsigned char WalPagelevelInsertKey[WAL_PAGELEVEL_INSERT_KEY_LEN] = {
	0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7,
	0xA8, 0xA9, 0xAA, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF,
	0xB0, 0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7,
	0xB8, 0xB9, 0xBA, 0xBB, 0xBC, 0xBD, 0xBE, 0xBF,
};
