const std = @import("std");

const TableError = error{
    InvalidIndex,
};

pub fn Table(comptime T: type, comptime R: type) type {
    comptime std.debug.assert(std.meta.hasFn(R, "pread"));
    return struct {
        const Self = @This();

        alloc: std.mem.Allocator,
        rdr: R,

        offset: u64,
        table_count: u32,
        mut: std.Thread.RwLock = .{},

        table: []T = &[0]T{},

        pub fn init(alloc: std.mem.Allocator, rdr: R, offset: u64, table_count: u32) Self {
            return .{
                .alloc = alloc,
                .rdr = rdr,
                .offset = offset,
                .table_count = table_count,
            };
        }
        pub fn deinit(self: Self) void {
            self.alloc.free(self.table);
        }

        fn resize(self: *Self, to_add: usize) !void {
            if (!self.alloc.resize(self.table, self.table.len + to_add)) {
                const new_table = try self.alloc.alloc(T, self.table.len + to_add);
                @memcpy(new_table[0..self.table.len], self.table);
                self.alloc.free(self.table);
                self.table = new_table;
            }
        }

        pub fn get(self: *Self, idx: u32) !T {
            if (idx >= self.table_count) return TableError.InvalidIndex;
            self.mut.lockShared();
            defer self.mut.unlockShared();
            if (idx >= self.table.len) {
                return self.getAndFill(idx);
            }
            return self.table[idx];
        }
        fn getAndFill(self: *Self, idx: u32) !T {
            self.mut.unlockShared();
            defer self.mut.lockShared();
            self.mut.lock();
            defer self.mut.unlock();
            var to_read: usize = 0;
            var offset: u64 = 0;
            while (idx >= self.table.len) {
                to_read = @min(self.table_count - self.table.len, comptime 8192 / @sizeOf(T));
                try self.resize(to_read);
                _ = try self.rdr.pread(std.mem.asBytes(&offset), self.offset);
                self.offset += 8;
                _ = try self.rdr.pread(std.mem.sliceAsBytes(self.table[self.table.len - to_read ..]), offset);
            }
            return self.table[idx];
        }
    };
}
