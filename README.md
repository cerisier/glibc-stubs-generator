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

## Resources

See https://github.com/ziglang/glibc-abi-tool for details about the `.abilist` 
file generation and format.
