const std = @import("std");

const PRdr = @import("util/p_rdr.zig").PRdr;
const DecompMgr = @import("util/decomp.zig");
const MetadataReader = @import("util/metadata.zig").MetadataReader;

pub const TableErr = error{invalidIndex};

pub fn Table(comptime T: type, comptime R: type) type {
    return struct {
        const Self = @This();

        alloc: std.mem.Allocator,
        rdr: PRdr(R),
        offset: u64,
        decomp: *DecompMgr,
        mut: std.Thread.RwLock = .{},

        num: u32,
        table: []T = &[0]T{},

        pub fn init(alloc: std.mem.Allocator, rdr: PRdr(R), offset: u64, decomp: *DecompMgr, num: u32) Self {
            return .{
                .alloc = alloc,
                .rdr = rdr,
                .offset = offset,
                .decomp = decomp,
                .num = num,
            };
        }
        pub fn deinit(self: Self) void {
            self.alloc.free(self.table);
        }

        pub fn get(self: *Self, idx: usize) !T {
            if (idx >= self.num) return TableErr.invalidIndex;
            self.mut.lockShared();
            if (self.table.len > idx) {
                defer self.mut.unlockShared();
                return self.table[idx];
            }
            self.mut.unlockShared();
            self.mut.lock();
            defer self.mut.unlock();
            while (self.table.len < idx) {
                const to_read = @min(comptime 8192 / @sizeOf(T), self.num - self.table.len);
                if (!self.alloc.resize(self.table, self.table.len + to_read)) {
                    var new_tab = try self.alloc.alloc(T, self.table.len + to_read);
                    @memcpy(new_tab[0..self.table.len], self.table);
                    self.alloc.free(self.table);
                    self.table = new_tab;
                }
                var offset: u64 = undefined;
                _ = try self.rdr.pread(std.mem.asBytes(&offset), self.offset);
                self.offset += 8;
                var meta_rdr: MetadataReader(R) = .init(self.rdr, offset, self.decomp);
                _ = try meta_rdr.read(std.mem.sliceAsBytes(self.table[self.table.len - to_read ..]));
            }
            return self.table[idx];
        }
    };
}
