# Copyright (c) 2022-2026, PostgreSQL Global Development Group

tests += {
  'name': 'wal_gcm_check',
  'sd': meson.current_source_dir(),
  'bd': meson.current_build_dir(),
  'tap': {
    'tests': [
    ],
    # Requires a cluster built with one of the per-record GCM variants,
    # which is a compile-time choice, so skip during installcheck.
    'runningcheck': false,
  },
}
