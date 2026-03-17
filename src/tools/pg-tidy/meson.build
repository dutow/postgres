# pg-tidy: clang-tidy checks for PostgreSQL
#
# This builds a clang-tidy plugin with PostgreSQL-specific checks.
# Requires LLVM/clang development libraries and clang-tidy.

if not pg_tidy_enabled
  subdir_done()
endif

pg_tidy_lib = shared_module('pg_tidy',
  'src/PgTidyModule.cpp',
  'src/PgNoPaddingCheck.cpp',
  'src/PgNoPaddingInitCheck.cpp',
  'src/PgRequiresNoPaddingCheck.cpp',
  dependencies: [llvm, clang_cpp_dep],
  cpp_args: ['-fno-exceptions'],
  override_options: ['cpp_std=c++17'],
)

# Run clang-tidy with pg-specific checks on each backend source file.
# Each file gets its own custom_target with a stamp file, so ninja can
# parallelize the checks and only re-run them when sources change.
python = find_program('python3')
pg_tidy_wrapper = meson.current_source_dir() / 'run_pg_tidy_file.py'

foreach srcfile : backend_sources
  srcfilename = fs.parent(srcfile) / fs.name(srcfile)
  targetname = 'pg_tidy_' + srcfilename.underscorify()

  custom_target(targetname,
    input: [srcfile],
    output: targetname + '.stamp',
    command: [
      python, pg_tidy_wrapper,
      clang_tidy_prog,
      pg_tidy_lib,
      meson.project_build_root(),
      '@INPUT@',
      '@OUTPUT@',
    ],
    depends: [pg_tidy_lib, generated_backend_headers_stamp],
    build_by_default: true,
  )
endforeach

# Tests require lit and FileCheck from LLVM
lit = find_program('lit', required: false)
filecheck = find_program('FileCheck', required: false)

if lit.found() and filecheck.found()
  lit_cfg_data = configuration_data()
  lit_cfg_data.set('CLANG_TIDY', clang_tidy_prog.full_path())
  lit_cfg_data.set('FILECHECK', filecheck.full_path())
  lit_cfg_data.set('PG_TIDY_LIB',
    meson.current_build_dir() / 'lib' + pg_tidy_lib.name() + '.so')
  lit_cfg_data.set('TEST_SOURCE_DIR', meson.current_source_dir() / 'test')
  lit_cfg_data.set('INCLUDE_DIR', meson.current_source_dir() / 'include')

  configure_file(
    input: 'test/lit.site.cfg.py.in',
    output: 'lit.site.cfg.py',
    configuration: lit_cfg_data,
  )

  test('pg-tidy-lit-tests', lit,
    args: [meson.current_build_dir(), '-v'],
    depends: [pg_tidy_lib],
  )
endif
