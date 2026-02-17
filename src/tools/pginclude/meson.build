# Copyright (c) 2026, PostgreSQL Global Development Group

# Register headerscheck tests.
#
# The headerscheck script reads compiler flags from src/Makefile.global,
# which meson populates via src/makefiles/meson.build (the same approach
# used for PGXS support).
#
# An alternative approach would be to implement the header checks
# natively in meson (discovering headers at configure time, generating
# test source files, and compiling them via static_library targets).
# That would integrate more tightly with meson's dependency system, but
# would add significant complexity to the build files compared to
# reusing the existing shell script.  It could be considered in the
# future if the make build is no longer needed.
#
# Run selectively with: meson test --suite headerscheck

headerscheck_script = find_program('headerscheck')

test('headerscheck',
  headerscheck_script,
  args: [meson.project_source_root(), meson.project_build_root()],
  depends: [generated_backend_headers_stamp],
  timeout: 600,
  suite: ['headerscheck'],
)

if have_cxx
  test('headerscheck-c++',
    headerscheck_script,
    args: ['--cplusplus',
           meson.project_source_root(), meson.project_build_root()],
    depends: [generated_backend_headers_stamp],
    timeout: 600,
    suite: ['headerscheck'],
  )
endif
