# glibc stubs generator

This program reads a consolidated `.abilist` of all `.abilist` files from every
version of glibc and generates stubs assembly files that can be used to
create glibc stubs given a target triple: `<arch>-<os>-gnu[<glibc_version>]`.

This stub can then be used to link against a specific version of the glibc for
any of the glibc supported platforms, without actually requiring to compile it
nor depending of target glibc prebuilts.

This program is mostly and extract of the zig programming language build source
code which is under MIT License.

## Running

```sh
$ zig run main.zig -- -target aarch64-linux-gnu.2.18 abilists -o asm
$ ls -la asm
drwxr-xr-x  11 root  staff     352 01 Jan 00:00 .
drwxr-xr-x  26 root  staff     832 01 Jan 00:00 ..
-rw-r--r--   1 root  staff     658 01 Jan 00:00 all.map
-rw-r--r--   1 root  staff  265786 01 Jan 00:00 c.s
-rw-r--r--   1 root  staff     935 01 Jan 00:00 dl.s
-rw-r--r--   1 root  staff    1323 01 Jan 00:00 ld.s
-rw-r--r--   1 root  staff  116122 01 Jan 00:00 m.s
-rw-r--r--   1 root  staff   38515 01 Jan 00:00 pthread.s
-rw-r--r--   1 root  staff   11918 01 Jan 00:00 resolv.s
-rw-r--r--   1 root  staff    4310 01 Jan 00:00 rt.s
-rw-r--r--   1 root  staff     645 01 Jan 00:00 util.s
```

> `abilists` can be obtained in the zig source code repository:
> 
> https://github.com/ziglang/zig/blob/3746b3d93ce895131ab1b2dea5391e5efa9fccf7/lib/libc/glibc/abilists

## Tests

Run `bazel test //tests/...`. The tests use the pinned Zig toolchain and its
glibc ABI data to generate and link stubs for x86_64, aarch64, and i386.
Executables that keep `_IO_stdin_used` local must link, including when a
version script localizes it. The fixture uses hidden visibility because
Zig 0.14 does not forward version scripts when linking executables;
the generated libc must omit the reference on newer ABIs and keep it weak
on ABIs with pre-2.1 libio compatibility. The cross-linked executables are
not run.

## Resources

See https://github.com/ziglang/glibc-abi-tool for details about the `.abilist` 
file generation and format.
