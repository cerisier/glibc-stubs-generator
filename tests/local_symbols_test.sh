#!/usr/bin/env bash
set -euo pipefail

generator="$PWD/$1"
zig="$TEST_SRCDIR/${2#external/}"
source_file="$PWD/$3"
target="$4"
reference="$5"

export ZIG_LIB_DIR="$(dirname "$zig")/lib"
export ZIG_GLOBAL_CACHE_DIR="$TEST_TMPDIR/zig-cache"
export ZIG_LOCAL_CACHE_DIR="$TEST_TMPDIR/zig-cache"
cd "$TEST_TMPDIR"

"$generator" -target "$target" -o stubs "$ZIG_LIB_DIR/libc/glibc/abilists"
# Legacy stubs place the CRT marker's dynamic relocation in .rodata.
"$zig" cc -target "$target" -nostdlib -shared \
    -Wl,-z,notext -Wl,-soname,libc.so.6 -Wl,--version-script,stubs/all.map \
    stubs/c.s -o libc.so.6

# The hidden CRT marker becomes local in the executable, just as with a
# version script. Zig 0.14 does not forward version scripts for executables.
# Enable lld's DSO checks (disabled by default in Zig) so a strong reference
# from libc makes it reject this link.
"$zig" cc -target "$target" -nostdlib -fno-stack-protector -no-pie \
    -Wl,--no-allow-shlib-undefined -Wl,-e,_start \
    "$source_file" ./libc.so.6 -o local_symbols

# Linking alone also accepts an omitted legacy reference, so check both
# sides of glibc's pre-2.1 libio compatibility contract.
case "$reference" in
    weak)
        grep -Fq '.weak _IO_stdin_used' stubs/c.s
        ;;
    absent)
        if grep -Fq '_IO_stdin_used' stubs/c.s; then
            echo "unexpected _IO_stdin_used reference for $target" >&2
            exit 1
        fi
        ;;
esac
