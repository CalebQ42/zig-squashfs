const std = @import("std");

pub const SfsReader = @import("reader.zig").SfsReader;
pub const ExtractionOptions = @import("extract_options.zig");

pub const SfsFile = SfsReader(std.fs.File);

const test_archive = "testing/LinuxPATest.sfs";

test "OpenFile" {
    const sfs_fil = try std.fs.cwd().openFile(test_archive, .{});
    defer sfs_fil.close();
    var rdr: SfsFile = try .init(std.testing.allocator, sfs_fil, 0);
    defer rdr.deinit();
    _ = try rdr.frag_table.get(rdr.super.frag_count - 1);
    _ = try rdr.id_table.get(rdr.super.id_count - 1);
    _ = try rdr.export_table.get(rdr.super.inode_count - 1);
    std.debug.print("{}\n", .{rdr.super});
    const root = try rdr.root();
    defer root.deinit();
    var iter = root.iterate();
    while (try iter.next()) |f| {
        defer f.deinit();
        std.debug.print("{s}\n", .{f.name});
    }
}

test "ExtractSingleFile" {
    const single_file = "PortableApps/Notepad++Portable/App/Notepad++/doLocalConf.xml";
    const single_file_extr_loc = "testing/doLocalConf.xml";

    std.fs.cwd().deleteFile(single_file_extr_loc) catch {};
    const sfs_fil = try std.fs.cwd().openFile(test_archive, .{});
    defer sfs_fil.close();
    var rdr: SfsFile = try .init(std.testing.allocator, sfs_fil, 0);
    defer rdr.deinit();
    const fil = try rdr.open(single_file);
    defer fil.deinit();
    var op: ExtractionOptions = try .init();
    op.verbose = true;
    try fil.extract(op, single_file_extr_loc);
}

test "ExtractAll" {
    const extr_dir = "testing/testExtract";

    std.fs.cwd().deleteTree(extr_dir) catch {};
    const sfs_fil = try std.fs.cwd().openFile(test_archive, .{});
    defer sfs_fil.close();
    var rdr: SfsFile = try .init(std.testing.allocator, sfs_fil, 0);
    defer rdr.deinit();
    const op: ExtractionOptions = try .init();
    // op.verbose = true;
    try rdr.extract(op, extr_dir);
}
