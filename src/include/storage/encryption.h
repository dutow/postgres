/*-------------------------------------------------------------------------
 *
 * encryption.h
 *	  Public plugin API for cluster encryption-at-rest (v2, unified).
 *
 * v2 collapses v1's positioned + stream families into a single contract
 * built around six callbacks.  Every encrypted object -- relation fork,
 * WAL stream, temp file, and future SLRU / 2PC -- flows through the same
 * methods.  Kind-specific behaviour is driven by data passed *into* the
 * methods (an EncryptionObjectIdent plus a per-kind IV-hint byte stream).
 *
 * Plugins are loaded via shared_preload_libraries and must call
 * RegisterEncryptionMethod() exactly once from _PG_init().  Core then
 * invokes cb->initialize() once and from then on consults the registered
 * callbacks at the hook points listed in the design document.
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * src/include/storage/encryption.h
 *
 *-------------------------------------------------------------------------
 */
#ifndef PG_ENCRYPTION_H
#define PG_ENCRYPTION_H

#include "common/relpath.h"
#include "storage/relfilelocator.h"

/*
 * ABI magic.  Bump whenever the callbacks struct or any of the types it
 * references changes shape in a way that would silently misinterpret an
 * older plugin's data.  Plugins must set
 * EncryptionMethodCallbacks.magic == PG_ENCRYPTION_METHOD_MAGIC; core
 * rejects mismatching registrations with ereport(ERROR).
 */
#define PG_ENCRYPTION_METHOD_MAGIC	0x20260512

/*
 * What kind of object the plugin is being asked to handle.  Values are
 * stable ABI: never renumber, never remove.  New kinds append at the end.
 *
 * The kind selects the per-kind IV-hint contract (see "iv_hint layout"
 * table in the v2 design document) and where core stores the
 * plugin-emitted persistent bytes:
 *
 *   LOGGED_RELATION, UNLOGGED_RELATION, TEMP_RELATION
 *       persistent ctx in block 0 of the relation's _enc fork
 *       (ENCRYPTION_FORKNUM), overhead in per-block slots of the same
 *       file.
 *   TEMP_FILE
 *       persistent ctx in process memory only; overhead interleaved
 *       per logical BufFile block.
 *   WAL
 *       persistent ctx in $PGDATA/global/pg_encryption_wal; overhead
 *       carried inside the WAL record (xl_tot_len grows by
 *       overhead_per_call).
 */
typedef enum EncryptionObjectKind
{
	ENC_OBJ_LOGGED_RELATION = 1,
	ENC_OBJ_UNLOGGED_RELATION = 2,
	ENC_OBJ_TEMP_RELATION = 3,	/* local temp tables (still smgr) */
	ENC_OBJ_TEMP_FILE = 4,		/* BufFile / sorts / hashagg spill */
	ENC_OBJ_WAL = 5,
	/* reserved: 6.. for SLRU, 2PC, replication state, etc. */
} EncryptionObjectKind;

/*
 * Identifies the specific object the plugin is being asked about.  All
 * fields meaningful for the relation kinds; for ENC_OBJ_WAL and
 * ENC_OBJ_TEMP_FILE the relation-specific fields are zeroed by core.
 *
 * relpersistence is RELPERSISTENCE_PERMANENT / _UNLOGGED / _TEMP for the
 * relation kinds and 0 otherwise.
 */
typedef struct EncryptionObjectIdent
{
	EncryptionObjectKind kind;
	RelFileNumber rel_number;
	Oid			db_oid;
	Oid			ts_oid;
	char		relpersistence;
} EncryptionObjectIdent;

/*
 * Runtime per-object state owned by the plugin.  The plugin allocates an
 * EncryptionContext (typically in TopMemoryContext or a long-lived child)
 * inside new_context / load_context and frees it from destroy_context.
 *
 * runtime_private is opaque to core; the plugin uses it for whatever
 * per-object derived state it needs (round keys, counters, scratch
 * buffers).  Core never inspects or copies it.
 */
typedef struct EncryptionContext
{
	/* Server's PG_VERSION_NUM at the time of registration. */
	int			sversion;

	/* Plugin's per-context state, opaque to core. */
	void	   *runtime_private;
} EncryptionContext;

/*
 * The unified six-callback plugin contract.
 *
 * Lifetime / critical-section discipline:
 *
 *   - initialize, new_context, load_context, destroy_context may
 *	   palloc and ereport.  They run outside critical sections.
 *
 *   - encrypt and decrypt are hot-path callbacks that may run inside a
 *	   critical section while the caller holds buffer or LWLocks.  They
 *	   MUST NOT palloc, MUST NOT ereport (other than PANIC for
 *	   unrecoverable cipher failure), and MUST NOT perform any operation
 *	   that can fail or longjmp.  All scratch state must be pre-allocated
 *	   during new_context / load_context.
 *
 * Both new_context and load_context may return false to declare "do
 * not encrypt this object".  Core caches that decision for the
 * object's lifetime; no error path is needed for the plaintext case.
 */
typedef struct EncryptionMethodCallbacks
{
	uint32		magic;			/* must equal PG_ENCRYPTION_METHOD_MAGIC */

	/*
	 * (1) Plugin one-time initialization, invoked exactly once by core
	 * after RegisterEncryptionMethod() has accepted the registration and
	 * shared_preload_libraries processing has completed.  May palloc /
	 * ereport.
	 */
	void		(*initialize) (void);

	/*
	 * (2) Build a fresh context for a newly-created object.
	 *
	 * Inputs:
	 *	 ident			- kind + identifying OIDs (for routing/keying).
	 *	 iv_hint_size	- bytes of IV-hint core will hand the plugin on
	 *					  every subsequent encrypt/decrypt call.  Fixed
	 *					  per kind (see the design doc's IV-hint table).
	 *
	 * Outputs (plugin fills on a `true` return):
	 *	 *ctx_out				 - runtime ctx, palloc'd by the plugin.
	 *	 *persistent_bytes_out	 - bytes core will save with the object.
	 *	 *persistent_len_out	 - byte count (may be 0).
	 *	 *overhead_per_call_out	 - extra bytes the plugin needs per
	 *							   encrypt call (0 = same-size scheme).
	 *
	 * Returning false means "do not encrypt this object".  The
	 * persistent_bytes_out buffer is borrowed: core copies it
	 * immediately into kind-specific storage, and the plugin may free
	 * its source after the call returns.
	 *
	 * May palloc and ereport.
	 */
	bool		(*new_context) (const EncryptionObjectIdent *ident,
								size_t iv_hint_size,
								EncryptionContext **ctx_out,
								const void **persistent_bytes_out,
								size_t *persistent_len_out,
								size_t *overhead_per_call_out);

	/*
	 * (3) Rebuild a context for an existing object.
	 *
	 * persistent_bytes / persistent_len are exactly what this plugin
	 * emitted from new_context at create time and which core stashed in
	 * kind-specific storage (the _enc fork header for relations,
	 * pg_encryption_wal for WAL, ...).  The plugin reconstructs whatever
	 * runtime state it needs and returns the same overhead_per_call it
	 * declared at create time.
	 *
	 * Returning false is treated the same as for new_context: the object
	 * is plaintext for the rest of its life in this process.  This is
	 * also how a plugin signals "the on-disk persistent bytes are
	 * unrecognisable" without ereporting from within smgr; for fatal
	 * mismatch the plugin may also PANIC.
	 *
	 * May palloc and ereport.
	 */
	bool		(*load_context) (const EncryptionObjectIdent *ident,
								 size_t iv_hint_size,
								 const void *persistent_bytes,
								 size_t persistent_len,
								 EncryptionContext **ctx_out,
								 size_t *overhead_per_call_out);

	/*
	 * (4) Encrypt one unit (whole BLCKSZ page, whole WAL record body,
	 * whole temp chunk).  Critical-section safe.
	 *
	 *	 out			- exactly `len` bytes (same-size cipher transform).
	 *	 overhead_out	- exactly overhead_per_call bytes, or NULL when
	 *					  overhead_per_call == 0.
	 *	 iv_hint		- iv_hint_size bytes; layout per kind (see design
	 *					  doc).  NULL when iv_hint_size == 0.
	 *
	 * in and out are caller-supplied; they may NOT alias (callers always
	 * pass distinct buffers).  MUST NOT palloc, MUST NOT ereport.
	 */
	void		(*encrypt) (EncryptionContext *ctx,
							const char *in, char *out, size_t len,
							char *overhead_out,
							const void *iv_hint, size_t iv_hint_size);

	/*
	 * (5) Inverse of encrypt.  overhead_in carries the bytes emitted by
	 * encrypt for this unit; iv_hint is again the per-kind hint stream.
	 *
	 * in and out may alias (xlogreader decrypts in place to avoid an
	 * extra copy); when they alias, the plugin must read each input byte
	 * before writing the corresponding output byte.  Same
	 * critical-section discipline as encrypt: MUST NOT palloc, MUST NOT
	 * ereport.
	 */
	void		(*decrypt) (EncryptionContext *ctx,
							const char *in, char *out, size_t len,
							const char *overhead_in,
							const void *iv_hint, size_t iv_hint_size);

	/*
	 * (6) Free the runtime context.  May palloc/pfree but should be
	 * cheap.
	 */
	void		(*destroy_context) (EncryptionContext *ctx);
} EncryptionMethodCallbacks;

/*
 * Registration entry points.  A plugin calls RegisterEncryptionMethod()
 * exactly once during _PG_init() while
 * process_shared_preload_libraries_in_progress is true.  Re-registration
 * is ereport(ERROR).  Core code looks up the active method via
 * GetEncryptionMethod(), which returns NULL when no plugin has registered.
 */
extern void RegisterEncryptionMethod(const EncryptionMethodCallbacks *cb);
extern const EncryptionMethodCallbacks *GetEncryptionMethod(void);

/*
 * Invoke the registered plugin's `initialize` callback exactly once per
 * process.  No-op when no plugin is registered or the callback has
 * already fired in this process.  Call sites: postmaster startup,
 * EXEC_BACKEND child setup, and single-user mode -- in each case right
 * after process_shared_preload_libraries() returns.
 */
extern void InitializeEncryptionMethod(void);

#endif							/* PG_ENCRYPTION_H */
