# Copyright (c) 2026, PostgreSQL Global Development Group

test_hba_guc_contexts_sources = files(
  'test_hba_guc_contexts.c',
)

if host_system == 'windows'
  test_hba_guc_contexts_sources += rc_lib_gen.process(win32ver_rc, extra_args: [
    '--NAME', 'test_hba_guc_contexts',
    '--FILEDESC', 'test_hba_guc_contexts - test module for PGC_HBA context validation',])
endif

test_hba_guc_contexts = shared_module('test_hba_guc_contexts',
  test_hba_guc_contexts_sources,
  kwargs: pg_test_mod_args,
)
test_install_libs += test_hba_guc_contexts

tests += {
  'name': 'test_hba_guc_contexts',
  'sd': meson.current_source_dir(),
  'bd': meson.current_build_dir(),
  'tap': {
    'tests': [
      't/001_context_validation.pl',
    ],
  },
}
