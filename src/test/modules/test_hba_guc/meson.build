# Copyright (c) 2026, PostgreSQL Global Development Group

test_hba_guc_sources = files(
  'test_hba_guc.c',
)

if host_system == 'windows'
  test_hba_guc_sources += rc_lib_gen.process(win32ver_rc, extra_args: [
    '--NAME', 'test_hba_guc',
    '--FILEDESC', 'test_hba_guc - test module for PGC_HBA GUC variables',])
endif

test_hba_guc = shared_module('test_hba_guc',
  test_hba_guc_sources,
  kwargs: pg_test_mod_args,
)
test_install_libs += test_hba_guc

test_install_data += files(
  'test_hba_guc.control',
  'test_hba_guc--1.0.sql',
)

tests += {
  'name': 'test_hba_guc',
  'sd': meson.current_source_dir(),
  'bd': meson.current_build_dir(),
  'tap': {
    'tests': [
      't/001_hba_guc_variables.pl',
      't/002_hba_guc_sources.pl',
      't/003_hba_guc_precedence.pl',
    ],
  },
}
