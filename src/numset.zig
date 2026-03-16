const std = @import("std");

pub const NumKind = enum {
    seq,
    uid,
};

pub const NumRange = struct {
    start: u32,
    stop: u32,

    pub fn contains(self: NumRange, value: u32) bool {
        if (self.stop == 0) return value >= self.start;
        const low = @min(self.start, self.stop);
        const high = @max(self.start, self.stop);
        return value >= low and value <= high;
    }

    pub fn dynamic(self: NumRange) bool {
        return self.start == 0 or self.stop == 0;
    }

    pub fn format(self: NumRange, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.start == self.stop and self.start != 0) {
            try writer.print("{d}", .{self.start});
            return;
        }
        if (self.start == 0) {
            try writer.writeAll("*");
        } else {
            try writer.print("{d}", .{self.start});
        }
        try writer.writeAll(":");
        if (self.stop == 0) {
            try writer.writeAll("*");
        } else {
            try writer.print("{d}", .{self.stop});
        }
    }
};

pub const NumSet = struct {
    allocator: std.mem.Allocator,
    kind: NumKind,
    ranges: std.ArrayList(NumRange),

    pub fn init(allocator: std.mem.Allocator, kind: NumKind) NumSet {
        return .{
            .allocator = allocator,
            .kind = kind,
            .ranges = .empty,
        };
    }

    pub fn deinit(self: *NumSet) void {
        self.ranges.deinit(self.allocator);
    }

    pub fn addNum(self: *NumSet, value: u32) !void {
        try self.ranges.append(self.allocator, .{ .start = value, .stop = value });
    }

    pub fn addRange(self: *NumSet, start: u32, stop: u32) !void {
        try self.ranges.append(self.allocator, .{ .start = start, .stop = stop });
    }

    pub fn contains(self: *const NumSet, value: u32) bool {
        for (self.ranges.items) |range| {
            if (range.contains(value)) return true;
        }
        return false;
    }

    pub fn dynamic(self: *const NumSet) bool {
        for (self.ranges.items) |range| {
            if (range.dynamic()) return true;
        }
        return false;
    }

    pub fn isEmpty(self: *const NumSet) bool {
        return self.ranges.items.len == 0;
    }

    pub fn format(self: NumSet, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.ranges.items, 0..) |range, index| {
            if (index != 0) try writer.writeAll(",");
            try writer.print("{f}", .{range});
        }
    }

    pub fn toOwnedString(self: *const NumSet, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{f}", .{self.*});
    }

    pub fn parse(allocator: std.mem.Allocator, kind: NumKind, input: []const u8) !NumSet {
        if (input.len == 0) return error.EmptyNumberSet;

        var result = NumSet.init(allocator, kind);
        errdefer result.deinit();

        var it = std.mem.splitScalar(u8, input, ',');
        while (it.next()) |part_raw| {
            const part = std.mem.trim(u8, part_raw, " \t");
            if (part.len == 0) return error.EmptyRange;

            if (std.mem.indexOfScalar(u8, part, ':')) |colon| {
                const left = part[0..colon];
                const right = part[colon + 1 ..];
                try result.addRange(try parseNum(left), try parseNum(right));
            } else {
                const value = try parseNum(part);
                try result.addNum(value);
            }
        }

        return result;
    }
};

fn parseNum(input: []const u8) !u32 {
    if (std.mem.eql(u8, input, "*")) return 0;
    const value = try std.fmt.parseInt(u32, input, 10);
    if (value == 0) return error.InvalidZero;
    return value;
}
