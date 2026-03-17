#!/usr/bin/env python3
"""Run clang-tidy with pg-tidy checks on a single source file."""

import subprocess
import sys


def main():
    clang_tidy = sys.argv[1]
    pg_tidy_lib = sys.argv[2]
    build_dir = sys.argv[3]
    source_file = sys.argv[4]
    stamp_file = sys.argv[5]

    result = subprocess.run([
        clang_tidy,
        '--load=' + pg_tidy_lib,
        '-checks=-*,pg-*',
        '-warnings-as-errors=pg-*',
        '-p', build_dir,
        source_file,
    ], capture_output=True, text=True)

    if result.returncode != 0:
        # Print clang-tidy output so the user sees the actual diagnostics
        if result.stdout:
            print(result.stdout, file=sys.stderr, end='')
        sys.exit(1)

    with open(stamp_file, 'w'):
        pass


if __name__ == '__main__':
    main()
