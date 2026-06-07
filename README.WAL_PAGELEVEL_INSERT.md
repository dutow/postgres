# WAL page-level CTR (insert-time) perf prototype

Throwaway, **page-level AES-256-CTR WAL encryption at insert time**
patch.  Page bodies are encrypted in `XLogCtl->pages` as records get
inserted; the disk-write boundary is a verbatim `pg_pwrite` of the
shared buffer.  Page headers stay plaintext.  IV is the page-start LSN.

Companion to:

* `patch_wal_pagelevel_ctr` — page-level CTR, encrypt at the
  **disk-write** boundary; shared WAL buffers stay plaintext.
* `patch_wal_ctr_perrecord` — per-record CTR, encrypt at insert.
* `patch_wal_gcm_perrecord` — per-record GCM, encrypt at insert.

The point of this branch is to measure whether moving page-level
encryption from `XLogWrite` into the WAL-insert critical section
materially hurts TPS on a high-concurrency workload, vs. the
write-time twin's deferred-encrypt cost.

**NOT for production.** Hardcoded key, no authentication, no plugin
API, no key management, no SGML docs.

See the upstream `README.md` for the actual PostgreSQL README — this
file is prototype-only.

## Build

```sh
bin/pg-build patch_wal_pagelevel_ctr_insert debug-meson
```

from the project root.  Build dir lands at
`build/patch_wal_pagelevel_ctr_insert/debug-meson/`, install dir at
`inst/patch_wal_pagelevel_ctr_insert/debug-meson/`.

## Architecture

**Encrypt scope is body only.** Bytes `[header_size, XLOG_BLCKSZ)` of
each page are CTR-encrypted; the page header (short or long) stays
plaintext both in shared memory and on disk.  This lets us avoid
re-encrypting the header on every modification (`xlp_rem_len` and
`xlp_info |= XLP_FIRST_IS_CONTRECORD` are assigned mid-record-copy in
`CopyXLogRecordToWAL`) and lets frontend tools parse `xlp_magic`,
`xlp_pageaddr`, `xlp_tli` directly without a decrypt step.

**In-memory invariant.** After `AdvanceXLInsertBuffer` initializes a
page, the body region holds raw CTR keystream (= encryption of
all-zero plaintext).  As `CopyXLogRecordToWAL` writes record bytes
into the page, each slice is encrypted in place.  Untouched body
bytes stay keystream; on read, they decrypt back to plaintext zero.
A partial page can be flushed at any moment and a future reader
decrypts: record positions → records, untouched positions → zero.

**Hook points.**

**Encrypt (plaintext → in-memory/on-disk ciphertext):**

* `AdvanceXLInsertBuffer` — keystream-fill the body after the existing
  `MemSet(NewPage, 0, XLOG_BLCKSZ)`.
* `CopyXLogRecordToWAL` — `WalPagelevelInsertEncrypt` replaces the two
  `memcpy(currpos, rdata_data, n)` slice copies.
* `BootStrapXLOG` — body-encrypt initdb's first checkpoint page before
  `pg_pwrite`.
* `XLogWalRcvWrite` — walreceiver body-encrypts wire bytes before
  `pg_pwrite` into the local pg_wal segment.
* `ProcessWALDataMsg` (`pg_basebackup/receivelog.c`) — same shape for
  streaming basebackup and `pg_receivewal`.
* `WriteEmptyXLOG` (`pg_resetwal`) — body-encrypt synthetic
  checkpoint page.
* `StartupXLOG` partial-page restore — after recovery copies the last
  partial page (plaintext) back into the shared buffer, re-encrypt
  its body and keystream-fill its tail.  Without this the shared
  buffer would diverge from the on-disk ciphertext for that page.

**Decrypt (on-disk ciphertext → plaintext):**

* `XLogPageRead` — recovery, after `pg_pread`.
* `WALRead` — walsender, `pg_waldump`, `pg_rewind`, after `pg_pread`.
* `WALReadFromBuffers` — walsender fast path; body bytes copied out of
  shared mem are decrypted in place after the second verification
  step.
* `SimpleXLogPageRead` (`pg_rewind/parsexlog.c`) — frontend direct
  `read()` of WAL segments bypasses `WALRead`, so decrypt explicitly.
* `read_archive_wal_page` (`pg_waldump/archive_waldump.c`) — tar
  archive read path for pg_verifybackup, bypasses `WALRead`.

**Disk-write is verbatim.** `XLogWrite` itself is untouched: bytes in
`XLogCtl->pages` go straight to disk.

**Crypto details.** AES-256-CTR.  Per-page IV = page-start LSN
serialized as 8 bytes big-endian + 8-byte counter block.  Bytes 0..7 of
the IV are the page-start LSN; bytes 8..15 advance by
`offset_in_page / 16` 128-bit blocks for offset-in-page CTR addressing.
Sub-block offsets (e.g. body-start at `SizeOfXLogShortPHD = 24` =
8 mod 16) are handled via the OpenSSL "discard prefix" trick (feed
`offset % 16` zero bytes through `EVP_EncryptUpdate` and ignore the
output to advance the keystream position).  Two pages can only reuse
the same IV if they sit at the same LSN, which never happens — IV
reuse is structurally absent.

## TAP test

`src/test/modules/wal_pagelevel_insert_check/t/001_wal_is_encrypted.pl`.
Same shape as the sibling `wal_pagelevel_check` test:

1. Start a cluster, insert an ASCII canary into a small table,
   `CHECKPOINT` and `pg_switch_wal()`.
2. Stop the server and `grep -a` every `pg_wal/*` segment for the
   canary — expects **zero** matches (body ciphertext hides it; the
   plaintext header carries no record data).
3. Restart and `SELECT` the canary row to confirm the decrypt path
   round-trips through crash recovery.

```sh
meson test -C build/patch_wal_pagelevel_ctr_insert/debug-meson/build \
    wal_pagelevel_insert_check/001_wal_is_encrypted
```

## Test suite status

As of the final phase, `meson test` is green except for one
fundamentally incompatible test:

* `recovery/039_end_of_wal` — injects raw plaintext WAL bytes and
  asserts plaintext error messages.  Incompatible with any WAL
  encryption scheme.

Two tests that the sibling `patch_wal_pagelevel_ctr` documents as
incompatible — `recovery/043_no_contrecord_switch` and
`pg_waldump/001_basic` subtest 45 — **pass** here.  Both depend on
manipulating page header bytes (overwriting `xlp_magic` directly,
expecting upstream plaintext semantics at the header).  Because this
prototype keeps headers plaintext, those raw-byte manipulations
behave as upstream and the tests succeed.

## Known limitations and explicit non-goals

* **Hardcoded 32-byte key in `src/common/wal_pagelevel_insert_key.c`.**
  Distinct from the sibling prototypes' keys, but still literally
  baked into every binary.  No GUC, no keyring, no rotation.
* **No authentication of any kind.** CRC is plaintext-computed at
  insert and plaintext-validated after decrypt; it catches accidental
  corruption but is trivially defeatable by any active attacker who
  knows the key (CTR is malleable).
* **Header metadata leaks on disk.** `xlp_magic`, `xlp_info`,
  `xlp_tli`, `xlp_pageaddr`, `xlp_rem_len`, and (on segment-first
  pages) `xlp_sysid`, `xlp_seg_size`, `xlp_xlog_blcksz` are all
  plaintext.  This is the architectural trade-off vs. the
  write-time pagelevel variant.
* **IV = page-start LSN, fixed and predictable.** Acceptable here
  because two pages sharing an IV would have to share an LSN, which
  never happens.
* **Insert-path latency cost is paid in the WAL insertion critical
  section.** This is the architectural risk the prototype exists to
  measure.  A record spanning many pages multiplies the per-page
  slice work synchronously inside the critical section.  No
  mitigation in this prototype; the bench harness will surface it.
* **Mixed-mode incompatibility.** Cannot read WAL produced by
  `master`, `patch_wal_pagelevel_ctr`, `patch_wal_gcm_perrecord`, or
  `patch_wal_ctr_perrecord` builds, and vice-versa.
* **WAL only.** No relation/page encryption, no temp file encryption,
  no SLRU encryption.
* **No SGML docs.** This README is the entire documentation surface.

## Bench harness — TODO

Not built yet.  Follow-up artifact should sweep `pgbench` across
`{master, patch_wal_pagelevel_ctr, patch_wal_pagelevel_ctr_insert,
patch_wal_gcm_perrecord, patch_wal_ctr_perrecord}`, snapshotting
`pg_stat_wal` and reporting TPS and bytes-per-txn deltas.  The
write-time vs. insert-time comparison is the headline number this
prototype exists to produce.

## Pointers

* Design doc:
  `/storage/pgwork/docs/plans/2026-06-07-wal-pagelevel-ctr-insert-prototype-design.md`
* Implementation plan:
  `/storage/pgwork/docs/plans/2026-06-07-wal-pagelevel-ctr-insert-prototype-implementation-plan.md`
* Core implementation: `src/common/wal_pagelevel_insert.c`,
  `src/common/wal_pagelevel_insert_key.c`,
  `src/include/common/wal_pagelevel_insert.h`
* TAP test:
  `src/test/modules/wal_pagelevel_insert_check/t/001_wal_is_encrypted.pl`
