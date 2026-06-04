# WAL GCM perf prototype

Throwaway, **per-record AES-256-GCM WAL encryption** patch used to measure the
overhead of always-on WAL record encryption under four compile-time variants.

**NOT for production.** Key is hardcoded, no plugin API, no key management, no
docs beyond this file. The branch exists solely to drive `pgbench` numbers and
to validate that per-record GCM is plumbed end-to-end through `XLogInsert`,
`XLogReadRecord`, and the frontend WAL tools (`pg_waldump`, `pg_rewind`,
`pg_resetwal`).

See the upstream `README.md` for the actual PostgreSQL README — this file is
prototype-only.

## What it does

* Reserves a new info bit `XLR_ENCRYPTED` in the WAL record header.
* Encrypts every WAL record body (everything after `XLogRecord`) with
  AES-256-GCM at `XLogInsert` time and decrypts at `XLogReadRecord` time.
* 12-byte IV + 16-byte tag are appended after the original body; the
  `xl_tot_len` is grown accordingly. `XLogRecordMaxSize` is asserted to still
  hold.
* Bootstrap (`xlog.c`) and `pg_resetwal`'s synthetic checkpoint records are
  encrypted the same way so that crash recovery and `pg_resetwal -f` round-trip
  cleanly.
* `wal_gcm.{c,h}` live in `src/common/` so frontend tools link against the
  same encrypt/decrypt helpers as the backend.
* The active variant is logged once at postmaster start.

## The four compile-time variants

Selected via two `-D` macros in `c_args`:

| Macro          | 0                 | 1                  |
| -------------- | ----------------- | ------------------ |
| `WAL_GCM_IV_MODE`  | random IV (`RAND_bytes`) | per-PID counter IV |
| `WAL_GCM_CTX_MODE` | reuse one EVP_CIPHER_CTX per backend | fresh ctx per call (`EVP_CIPHER_CTX_new`/`_free`) |

The four configs in `/storage/pgwork/configs/`:

```
wal-gcm-rand-reuse.yaml    IV=0 CTX=0   (baseline encrypted)
wal-gcm-rand-percall.yaml  IV=0 CTX=1   (ctx alloc cost)
wal-gcm-ctr-reuse.yaml     IV=1 CTX=0   (cheap IV + reused ctx)
wal-gcm-ctr-percall.yaml   IV=1 CTX=1   (cheap IV alone)
```

Build all four:

```sh
bin/build-wal-gcm-variants
```

…which loops over the configs and invokes `bin/pg-build patch_wal_gcm_perrecord
<variant>`. Single variant:

```sh
bin/pg-build patch_wal_gcm_perrecord wal-gcm-ctr-reuse
```

Resulting build dir: `build/patch_wal_gcm_perrecord/<variant>/`; install dir:
`inst/patch_wal_gcm_perrecord/<variant>/`.

## TAP test

`src/test/modules/wal_gcm_check/t/001_wal_is_encrypted.pl` is the one new test.
It:

1. Starts a fresh cluster, creates `t(c text)`, inserts a 50-byte ASCII
   canary, `CHECKPOINT`s and `pg_switch_wal()`s.
2. Stops the server and `grep`s every `pg_wal/*` segment for the canary —
   expects **zero** matches (i.e. the WAL on disk is ciphertext).
3. Restarts the cluster and `SELECT count(*) FROM t WHERE c = '<canary>'`
   to confirm the decrypt path round-trips through crash recovery.

Run it under any of the variants:

```sh
meson test -C build/patch_wal_gcm_perrecord/<variant>/build \
    wal_gcm_check/001_wal_is_encrypted
```

## Known limitations

* **Hardcoded 32-byte AES key in `src/common/wal_gcm_key.c`.** Never ship.
  There is no GUC, no keyring, no rotation — the literal key is baked into
  every binary in the build.
* **`WAL_GCM_IV_MODE=1` is unsafe across same-PID backend restarts.** The
  counter lives in backend-local memory; if the OS reuses a PID after a
  backend exit there is no persisted counter state and you can get
  `(key, IV)` reuse, which destroys GCM's confidentiality and integrity.
  Fine for short pgbench runs; not production.
* **WAL only.** No relation page encryption, no temp file encryption, no
  SLRU encryption, no replication slot data, no logical decoding output.
* **No SGML docs.** This README is the entire documentation surface.
* **`recovery/039_end_of_wal`'s "xlp_magic zero (split record header)"
  subtest fails** under this prototype. That subtest deliberately injects
  WAL corruption patterns that interact with always-on encryption (the
  injected bytes are no longer the bytes the decrypter sees). Accepted as a
  known pre-existing failure for the prototype — `376/1/19` is the expected
  result line.
* **Requires OpenSSL 3.0+.** Uses `EVP_EncryptInit_ex2` /
  `EVP_DecryptInit_ex2`, which are 3.0-only entry points.
* **Frontend tools' `WalGcmInit` is a no-op** for cleanup — there is no
  MemoryContext / `before_shmem_exit` machinery in frontend code, so under
  `WAL_GCM_CTX_MODE=0` (reuse) the per-process `EVP_CIPHER_CTX` leaks at
  frontend exit. Acceptable for one-shot tools like `pg_waldump`,
  `pg_rewind`, `pg_resetwal`.

## Bench harness — TODO

Not built yet. Sketch of what `bin/bench_wal_gcm.sh` should do:

* For each of `{master baseline, rand-reuse, rand-percall, ctr-reuse,
  ctr-percall}`:
  * `initdb`, start, run `pgbench -i -s 50`, then
    `pgbench -t 60 -c $N -j $N` across a sweep of `$N`.
  * Snapshot `pg_stat_wal.{wal_records, wal_bytes, wal_fpi}` before/after.
  * Snapshot `pg_stat_io` (if available) to get per-segment write throughput.
* Report TPS deltas vs. master and bytes-per-txn deltas across variants.
* Capture `perf stat` for the backend driving the benchmark if possible.

## Pointers

* Design doc: `/storage/pgwork/docs/plans/2026-06-04-wal-perrecord-gcm-prototype-design.md`
* Implementation plan: `/storage/pgwork/docs/plans/2026-06-04-wal-perrecord-gcm-prototype-implementation-plan.md`
* Variant configs: `/storage/pgwork/configs/wal-gcm-*.yaml`
* Build helper: `/storage/pgwork/bin/build-wal-gcm-variants`
* Core implementation: `src/common/wal_gcm.c`, `src/common/wal_gcm_key.c`,
  `src/include/common/wal_gcm.h`
* TAP test: `src/test/modules/wal_gcm_check/t/001_wal_is_encrypted.pl`
