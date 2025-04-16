// This file combines code derived from the Zig programming language,
// which is licensed under the MIT License.
//
// Original source:
// - https://github.com/ziglang/zig/blob/e62352611faf3056b989cc1edaa4aedaa74f326e/src/glibc.zig
//
// Copyright (c) 2021 Zig contributors

const std = @import("std");
const Allocator = std.mem.Allocator;
const mem = std.mem;
const log = std.log;
const fs = std.fs;
const path = fs.path;
const Version = std.SemanticVersion;

const usage =
    \\Usage: ./glibc-stubs-generator abilists_path
    \\
    \\    Parse an abilists file and generate assembly files for the glibc stubs.
    \\
    \\Options:
    \\  -h, --help             Print this help and exit
    \\  -target [name]         <arch><sub>-<os>-<abi> see the targets command (linux only)
    \\  -o, --output-dir       The base output directory for the generated files
    \\
;

pub const Lib = struct {
    name: []const u8,
    sover: u8,
    removed_in: ?Version = null,
};

pub const ABI = struct {
    all_versions: []const Version, // all defined versions (one abilist from v2.0.0 up to current)
    all_targets: []const std.zig.target.ArchOsAbi,
    /// The bytes from the file verbatim, starting from the u16 number
    /// of function inclusions.
    inclusions: []const u8,
    arena_state: std.heap.ArenaAllocator.State,

    pub fn destroy(abi: *ABI, gpa: Allocator) void {
        abi.arena_state.promote(gpa).deinit();
    }
};

// The order of the elements in this array defines the linking order.
pub const libs = [_]Lib{
    .{ .name = "m", .sover = 6 },
    .{ .name = "pthread", .sover = 0, .removed_in = .{ .major = 2, .minor = 34, .patch = 0 } },
    .{ .name = "c", .sover = 6 },
    .{ .name = "dl", .sover = 2, .removed_in = .{ .major = 2, .minor = 34, .patch = 0 } },
    .{ .name = "rt", .sover = 1, .removed_in = .{ .major = 2, .minor = 34, .patch = 0 } },
    .{ .name = "ld", .sover = 2 },
    .{ .name = "util", .sover = 1, .removed_in = .{ .major = 2, .minor = 34, .patch = 0 } },
    .{ .name = "resolv", .sover = 2 },
};

pub const LoadMetaDataError = error{
    /// The files that ship with the Zig compiler were unable to be read, or otherwise had malformed data.
    ZigInstallationCorrupt,
    OutOfMemory,
};

pub const abilists_max_size = 800 * 1024; // Bigger than this and something is definitely borked.

/// This function will emit a log error when there is a problem with the zig
/// installation and then return `error.ZigInstallationCorrupt`.
pub fn loadMetaData(gpa: Allocator, contents: []const u8) LoadMetaDataError!*ABI {
    var arena_allocator = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    var index: usize = 0;

    {
        const libs_len = contents[index];
        index += 1;

        var i: u8 = 0;
        while (i < libs_len) : (i += 1) {
            const lib_name = mem.sliceTo(contents[index..], 0);
            index += lib_name.len + 1;

            if (i >= libs.len or !mem.eql(u8, libs[i].name, lib_name)) {
                log.err("libc" ++ path.sep_str ++ "glibc" ++ path.sep_str ++
                    "abilists: invalid library name or index ({d}): '{s}'", .{ i, lib_name });
                return error.ZigInstallationCorrupt;
            }
        }
    }

    const versions = b: {
        const versions_len = contents[index];
        index += 1;

        const versions = try arena.alloc(Version, versions_len);
        var i: u8 = 0;
        while (i < versions.len) : (i += 1) {
            versions[i] = .{
                .major = contents[index + 0],
                .minor = contents[index + 1],
                .patch = contents[index + 2],
            };
            index += 3;
        }
        break :b versions;
    };

    const targets = b: {
        const targets_len = contents[index];
        index += 1;

        const targets = try arena.alloc(std.zig.target.ArchOsAbi, targets_len);
        var i: u8 = 0;
        while (i < targets.len) : (i += 1) {
            const target_name = mem.sliceTo(contents[index..], 0);
            index += target_name.len + 1;

            var component_it = mem.tokenizeScalar(u8, target_name, '-');
            const arch_name = component_it.next() orelse {
                log.err("abilists: expected arch name", .{});
                return error.ZigInstallationCorrupt;
            };
            const os_name = component_it.next() orelse {
                log.err("abilists: expected OS name", .{});
                return error.ZigInstallationCorrupt;
            };
            const abi_name = component_it.next() orelse {
                log.err("abilists: expected ABI name", .{});
                return error.ZigInstallationCorrupt;
            };
            const arch_tag = std.meta.stringToEnum(std.Target.Cpu.Arch, arch_name) orelse {
                log.err("abilists: unrecognized arch: '{s}'", .{arch_name});
                return error.ZigInstallationCorrupt;
            };
            if (!mem.eql(u8, os_name, "linux")) {
                log.err("abilists: expected OS 'linux', found '{s}'", .{os_name});
                return error.ZigInstallationCorrupt;
            }
            const abi_tag = std.meta.stringToEnum(std.Target.Abi, abi_name) orelse {
                log.err("abilists: unrecognized ABI: '{s}'", .{abi_name});
                return error.ZigInstallationCorrupt;
            };

            targets[i] = .{
                .arch = arch_tag,
                .os = .linux,
                .abi = abi_tag,
            };
        }
        break :b targets;
    };

    const abi = try arena.create(ABI);
    abi.* = .{
        .all_versions = versions,
        .all_targets = targets,
        .inclusions = contents[index..],
        .arena_state = arena_allocator.state,
    };
    return abi;
}


const all_map_basename = "all.map";

fn wordDirective(target: std.Target) []const u8 {
    // Based on its description in the GNU `as` manual, you might assume that `.word` is sized
    // according to the target word size. But no; that would just make too much sense.
    return if (target.ptrBitWidth() == 64) ".quad" else ".long";
}

pub fn buildSharedObjects(o_directory: *fs.Dir, target: std.Target, abilists_path: []const u8) anyerror!void {

    var general_purpose_allocator: std.heap.GeneralPurposeAllocator(.{}) = .init;
    const gpa = general_purpose_allocator.allocator();

    var arena_allocator = std.heap.ArenaAllocator.init(gpa);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    const target_version = target.os.versionRange().gnuLibCVersion().?;
    const abilists_contents = try std.fs.cwd().readFileAlloc(gpa, abilists_path, std.math.maxInt(usize));

    const metadata = try loadMetaData(gpa, abilists_contents);
    defer metadata.destroy(gpa);

    const target_targ_index = for (metadata.all_targets, 0..) |targ, i| {
        if (targ.arch == target.cpu.arch and
            targ.os == target.os.tag and
            targ.abi == target.abi)
        {
            break i;
        }
    } else {
        unreachable; // std.zig.target.available_libcs prevents us from getting here
    };

    const target_ver_index = for (metadata.all_versions, 0..) |ver, i| {
        switch (ver.order(target_version)) {
            .eq => break i,
            .lt => continue,
            .gt => {
                // TODO Expose via compile error mechanism instead of log.
                log.warn("invalid target glibc version: {}", .{target_version});
                return error.InvalidTargetGLibCVersion;
            },
        }
    } else blk: {
        const latest_index = metadata.all_versions.len - 1;
        log.warn("zig cannot build new glibc version {}; providing instead {}", .{
            target_version, metadata.all_versions[latest_index],
        });
        break :blk latest_index;
    };

    {
        var map_contents = std.ArrayList(u8).init(arena);
        for (metadata.all_versions[0 .. target_ver_index + 1]) |ver| {
            if (ver.patch == 0) {
                try map_contents.writer().print("GLIBC_{d}.{d} {{ }};\n", .{ ver.major, ver.minor });
            } else {
                try map_contents.writer().print("GLIBC_{d}.{d}.{d} {{ }};\n", .{ ver.major, ver.minor, ver.patch });
            }
        }

        try o_directory.writeFile(.{ .sub_path = all_map_basename, .data = map_contents.items });

        map_contents.deinit(); // The most recent allocation of an arena can be freed :)
    }


    var stubs_asm = std.ArrayList(u8).init(gpa);
    defer stubs_asm.deinit();

    for (libs, 0..) |lib, lib_i| {

        if (lib.removed_in) |rem_in| {
            if (target_version.order(rem_in) != .lt) continue;
        }

        stubs_asm.shrinkRetainingCapacity(0);
        try stubs_asm.appendSlice(".text\n");

        var sym_i: usize = 0;
        var sym_name_buf = std.ArrayList(u8).init(arena);
        var opt_symbol_name: ?[]const u8 = null;
        var versions_buffer: [32]u8 = undefined;
        var versions_len: usize = undefined;

        // There can be situations where there are multiple inclusions for the same symbol with
        // partially overlapping versions, due to different target lists. For example:
        //
        //  lgammal:
        //   library: libm.so
        //   versions: 2.4 2.23
        //   targets: ... powerpc64-linux-gnu s390x-linux-gnu
        //  lgammal:
        //   library: libm.so
        //   versions: 2.2 2.23
        //   targets: sparc64-linux-gnu s390x-linux-gnu
        //
        // If we don't handle this, we end up writing the default `lgammal` symbol for version 2.33
        // twice, which causes a "duplicate symbol" assembler error.
        var versions_written = std.AutoArrayHashMap(Version, void).init(arena);

        var inc_fbs = std.io.fixedBufferStream(metadata.inclusions);
        var inc_reader = inc_fbs.reader();

        const fn_inclusions_len = try inc_reader.readInt(u16, .little);

        while (sym_i < fn_inclusions_len) : (sym_i += 1) {
            const sym_name = opt_symbol_name orelse n: {
                sym_name_buf.clearRetainingCapacity();
                try inc_reader.streamUntilDelimiter(sym_name_buf.writer(), 0, null);

                opt_symbol_name = sym_name_buf.items;
                versions_buffer = undefined;
                versions_len = 0;

                break :n sym_name_buf.items;
            };
            const targets = try std.leb.readUleb128(u64, inc_reader);
            var lib_index = try inc_reader.readByte();

            const is_terminal = (lib_index & (1 << 7)) != 0;
            if (is_terminal) {
                lib_index &= ~@as(u8, 1 << 7);
                opt_symbol_name = null;
            }

            // Test whether the inclusion applies to our current library and target.
            const ok_lib_and_target =
                (lib_index == lib_i) and
                ((targets & (@as(u64, 1) << @as(u6, @intCast(target_targ_index)))) != 0);

            while (true) {
                const byte = try inc_reader.readByte();
                const last = (byte & 0b1000_0000) != 0;
                const ver_i = @as(u7, @truncate(byte));
                if (ok_lib_and_target and ver_i <= target_ver_index) {
                    versions_buffer[versions_len] = ver_i;
                    versions_len += 1;
                }
                if (last) break;
            }

            if (!is_terminal) continue;

            // Pick the default symbol version:
            // - If there are no versions, don't emit it
            // - Take the greatest one <= than the target one
            // - If none of them is <= than the
            //   specified one don't pick any default version
            if (versions_len == 0) continue;
            var chosen_def_ver_index: u8 = 255;
            {
                var ver_buf_i: u8 = 0;
                while (ver_buf_i < versions_len) : (ver_buf_i += 1) {
                    const ver_index = versions_buffer[ver_buf_i];
                    if (chosen_def_ver_index == 255 or ver_index > chosen_def_ver_index) {
                        chosen_def_ver_index = ver_index;
                    }
                }
            }

            versions_written.clearRetainingCapacity();
            try versions_written.ensureTotalCapacity(versions_len);

            {
                var ver_buf_i: u8 = 0;
                while (ver_buf_i < versions_len) : (ver_buf_i += 1) {
                    // Example:
                    // .balign 4
                    // .globl _Exit_2_2_5
                    // .type _Exit_2_2_5, %function;
                    // .symver _Exit_2_2_5, _Exit@@GLIBC_2.2.5
                    // _Exit_2_2_5: .long 0
                    const ver_index = versions_buffer[ver_buf_i];
                    const ver = metadata.all_versions[ver_index];

                    if (versions_written.getOrPutAssumeCapacity(ver).found_existing) continue;

                    // Default symbol version definition vs normal symbol version definition
                    const want_default = chosen_def_ver_index != 255 and ver_index == chosen_def_ver_index;
                    const at_sign_str: []const u8 = if (want_default) "@@" else "@";
                    if (ver.patch == 0) {
                        const sym_plus_ver = if (want_default)
                            sym_name
                        else
                            try std.fmt.allocPrint(
                                arena,
                                "{s}_GLIBC_{d}_{d}",
                                .{ sym_name, ver.major, ver.minor },
                            );
                        try stubs_asm.writer().print(
                            \\.balign {d}
                            \\.globl {s}
                            \\.type {s}, %function;
                            \\.symver {s}, {s}{s}GLIBC_{d}.{d}
                            \\{s}: {s} 0
                            \\
                        , .{
                            target.ptrBitWidth() / 8,
                            sym_plus_ver,
                            sym_plus_ver,
                            sym_plus_ver,
                            sym_name,
                            at_sign_str,
                            ver.major,
                            ver.minor,
                            sym_plus_ver,
                            wordDirective(target),
                        });
                    } else {
                        const sym_plus_ver = if (want_default)
                            sym_name
                        else
                            try std.fmt.allocPrint(
                                arena,
                                "{s}_GLIBC_{d}_{d}_{d}",
                                .{ sym_name, ver.major, ver.minor, ver.patch },
                            );
                        try stubs_asm.writer().print(
                            \\.balign {d}
                            \\.globl {s}
                            \\.type {s}, %function;
                            \\.symver {s}, {s}{s}GLIBC_{d}.{d}.{d}
                            \\{s}: {s} 0
                            \\
                        , .{
                            target.ptrBitWidth() / 8,
                            sym_plus_ver,
                            sym_plus_ver,
                            sym_plus_ver,
                            sym_name,
                            at_sign_str,
                            ver.major,
                            ver.minor,
                            ver.patch,
                            sym_plus_ver,
                            wordDirective(target),
                        });
                    }
                }
            }
        }

        try stubs_asm.appendSlice(".rodata\n");

        // For some targets, the real `libc.so.6` will contain a weak reference to `_IO_stdin_used`,
        // making the linker put the symbol in the dynamic symbol table. We likewise need to emit a
        // reference to it here for that effect, or it will not show up, which in turn will cause
        // the real glibc to think that the program was built against an ancient `FILE` structure
        // (pre-glibc 2.1).
        //
        // Note that glibc only compiles in the legacy compatibility code for some targets; it
        // depends on what is defined in the `shlib-versions` file for the particular architecture
        // and ABI. Those files are preprocessed by 2 separate tools during the glibc build to get
        // the final `abi-versions.h`, so it would be quite brittle to try to condition our emission
        // of the `_IO_stdin_used` reference in the exact same way. The only downside of emitting
        // the reference unconditionally is that it ends up being unused for newer targets; it
        // otherwise has no negative effect.
        //
        // glibc uses a weak reference because it has to work with programs compiled against pre-2.1
        // versions where the symbol didn't exist. We only care about modern glibc versions, so use
        // a strong reference.
        if (std.mem.eql(u8, lib.name, "c")) {
            try stubs_asm.writer().print(
                \\.balign {d}
                \\.globl _IO_stdin_used
                \\{s} _IO_stdin_used
                \\
            , .{
                target.ptrBitWidth() / 8,
                wordDirective(target),
            });
        }

        try stubs_asm.appendSlice(".data\n");

        const obj_inclusions_len = try inc_reader.readInt(u16, .little);

        sym_i = 0;
        opt_symbol_name = null;
        versions_buffer = undefined;
        versions_len = undefined;
        while (sym_i < obj_inclusions_len) : (sym_i += 1) {
            const sym_name = opt_symbol_name orelse n: {
                sym_name_buf.clearRetainingCapacity();
                try inc_reader.streamUntilDelimiter(sym_name_buf.writer(), 0, null);

                opt_symbol_name = sym_name_buf.items;
                versions_buffer = undefined;
                versions_len = 0;

                break :n sym_name_buf.items;
            };
            const targets = try std.leb.readUleb128(u64, inc_reader);
            const size = try std.leb.readUleb128(u16, inc_reader);
            var lib_index = try inc_reader.readByte();

            const is_terminal = (lib_index & (1 << 7)) != 0;
            if (is_terminal) {
                lib_index &= ~@as(u8, 1 << 7);
                opt_symbol_name = null;
            }

            // Test whether the inclusion applies to our current library and target.
            const ok_lib_and_target =
                (lib_index == lib_i) and
                ((targets & (@as(u64, 1) << @as(u6, @intCast(target_targ_index)))) != 0);

            while (true) {
                const byte = try inc_reader.readByte();
                const last = (byte & 0b1000_0000) != 0;
                const ver_i = @as(u7, @truncate(byte));
                if (ok_lib_and_target and ver_i <= target_ver_index) {
                    versions_buffer[versions_len] = ver_i;
                    versions_len += 1;
                }
                if (last) break;
            }

            if (!is_terminal) continue;

            // Pick the default symbol version:
            // - If there are no versions, don't emit it
            // - Take the greatest one <= than the target one
            // - If none of them is <= than the
            //   specified one don't pick any default version
            if (versions_len == 0) continue;
            var chosen_def_ver_index: u8 = 255;
            {
                var ver_buf_i: u8 = 0;
                while (ver_buf_i < versions_len) : (ver_buf_i += 1) {
                    const ver_index = versions_buffer[ver_buf_i];
                    if (chosen_def_ver_index == 255 or ver_index > chosen_def_ver_index) {
                        chosen_def_ver_index = ver_index;
                    }
                }
            }

            versions_written.clearRetainingCapacity();
            try versions_written.ensureTotalCapacity(versions_len);

            {
                var ver_buf_i: u8 = 0;
                while (ver_buf_i < versions_len) : (ver_buf_i += 1) {
                    // Example:
                    // .balign 4
                    // .globl environ_2_2_5
                    // .type environ_2_2_5, %object;
                    // .size environ_2_2_5, 4;
                    // .symver environ_2_2_5, environ@@GLIBC_2.2.5
                    // environ_2_2_5: .fill 4, 1, 0
                    const ver_index = versions_buffer[ver_buf_i];
                    const ver = metadata.all_versions[ver_index];

                    if (versions_written.getOrPutAssumeCapacity(ver).found_existing) continue;

                    // Default symbol version definition vs normal symbol version definition
                    const want_default = chosen_def_ver_index != 255 and ver_index == chosen_def_ver_index;
                    const at_sign_str: []const u8 = if (want_default) "@@" else "@";
                    if (ver.patch == 0) {
                        const sym_plus_ver = if (want_default)
                            sym_name
                        else
                            try std.fmt.allocPrint(
                                arena,
                                "{s}_GLIBC_{d}_{d}",
                                .{ sym_name, ver.major, ver.minor },
                            );
                        try stubs_asm.writer().print(
                            \\.balign {d}
                            \\.globl {s}
                            \\.type {s}, %object;
                            \\.size {s}, {d};
                            \\.symver {s}, {s}{s}GLIBC_{d}.{d}
                            \\{s}: .fill {d}, 1, 0
                            \\
                        , .{
                            target.ptrBitWidth() / 8,
                            sym_plus_ver,
                            sym_plus_ver,
                            sym_plus_ver,
                            size,
                            sym_plus_ver,
                            sym_name,
                            at_sign_str,
                            ver.major,
                            ver.minor,
                            sym_plus_ver,
                            size,
                        });
                    } else {
                        const sym_plus_ver = if (want_default)
                            sym_name
                        else
                            try std.fmt.allocPrint(
                                arena,
                                "{s}_GLIBC_{d}_{d}_{d}",
                                .{ sym_name, ver.major, ver.minor, ver.patch },
                            );
                        try stubs_asm.writer().print(
                            \\.balign {d}
                            \\.globl {s}
                            \\.type {s}, %object;
                            \\.size {s}, {d};
                            \\.symver {s}, {s}{s}GLIBC_{d}.{d}.{d}
                            \\{s}: .fill {d}, 1, 0
                            \\
                        , .{
                            target.ptrBitWidth() / 8,
                            sym_plus_ver,
                            sym_plus_ver,
                            sym_plus_ver,
                            size,
                            sym_plus_ver,
                            sym_name,
                            at_sign_str,
                            ver.major,
                            ver.minor,
                            ver.patch,
                            sym_plus_ver,
                            size,
                        });
                    }
                }
            }
        }

        var lib_name_buf: [32]u8 = undefined; // Larger than each of the names "c", "pthread", etc.
        const asm_file_basename = std.fmt.bufPrint(&lib_name_buf, "{s}.s", .{lib.name}) catch unreachable;
        try o_directory.writeFile(.{ .sub_path = asm_file_basename, .data = stubs_asm.items });
    }
}

pub fn main() anyerror!void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.process.argsAlloc(arena);

    var target_arch_os_abi: ?[]const u8 = null;
    var o_base_directory_path: []const u8 = "build";
    var abilists_path: ?[]const u8 = null;
    {
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (mem.startsWith(u8, arg, "-")) {
                if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help")) {
                    const stdout = std.io.getStdOut().writer();
                    try stdout.writeAll(usage);
                    return std.process.cleanExit();
                } else if (mem.eql(u8, arg, "-target")) {
                    if (i + 1 >= args.len) fatal("expected parameter after {s}", .{arg});
                    i += 1;
                    target_arch_os_abi = args[i];
                } else if (mem.eql(u8, arg, "-o") or mem.eql(u8, arg, "--output-dir")) {
                    if (i + 1 >= args.len) fatal("expected parameter after {s}", .{arg});
                    i += 1;
                    o_base_directory_path = args[i];
                } else {
                    fatal("unrecognized parameter: '{s}'", .{arg});
                }
            } else if (abilists_path != null) {
                fatal("unexpected extra parameter: '{s}'", .{arg});
            } else {
                abilists_path = arg;
            }
        }
    }

    if (target_arch_os_abi == null) {
        fatal("missing required parameter: '-target'", .{});
    }

    if (abilists_path == null) {
        const stdout = std.io.getStdErr().writer();
        try stdout.writeAll(usage);
        std.process.exit(1);
    }

const target_query = std.zig.parseTargetQueryOrReportFatalError(arena, .{
        .arch_os_abi = target_arch_os_abi.?,
    });
    const target = std.zig.resolveTargetQueryOrFatal(target_query);

    // const linux_triple = try target.linuxTriple(arena);
    // const o_directory_path = try std.fmt.allocPrint(arena, "{s}" ++ path.sep_str ++ "{s}", .{o_base_directory_path, linux_triple});
    var o_directory: fs.Dir = try fs.cwd().makeOpenPath(o_base_directory_path, .{});

    try buildSharedObjects(&o_directory, target,  abilists_path.?);
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.log.err(format, args);
    std.process.exit(1);
}
