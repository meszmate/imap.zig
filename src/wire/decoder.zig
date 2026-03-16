const std = @import("std");

pub const TokenKind = enum {
    atom,
    quoted,
    nil,
    list_start,
    list_end,
    literal,
};

pub const Token = struct {
    kind: TokenKind,
    value: []const u8 = "",
};

pub const LiteralInfo = struct {
    size: usize,
    synchronizing: bool = true,
    binary: bool = false,
};

pub fn parseLiteralMarker(text: []const u8) ?LiteralInfo {
    if (text.len < 3) return null;
    var start: usize = 0;
    var binary = false;
    if (text[0] == '~') {
        binary = true;
        start = 1;
    }
    if (text[start] != '{') return null;
    const end = std.mem.indexOfScalar(u8, text[start..], '}') orelse return null;
    const inner = text[start + 1 .. start + end];
    if (inner.len == 0) return null;
    var synchronizing = true;
    var size_str = inner;
    if (inner[inner.len - 1] == '+') {
        synchronizing = false;
        size_str = inner[0 .. inner.len - 1];
    } else if (inner[inner.len - 1] == '-') {
        synchronizing = false;
        size_str = inner[0 .. inner.len - 1];
    }
    const size = std.fmt.parseInt(usize, size_str, 10) catch return null;
    return LiteralInfo{
        .size = size,
        .synchronizing = synchronizing,
        .binary = binary,
    };
}

pub const Decoder = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    index: usize = 0,

    pub fn init(allocator: std.mem.Allocator, input: []const u8) Decoder {
        return .{
            .allocator = allocator,
            .input = input,
        };
    }

    pub fn next(self: *Decoder) !?Token {
        self.skipSpaces();
        if (self.index >= self.input.len) return null;

        const byte = self.input[self.index];
        switch (byte) {
            '(' => {
                self.index += 1;
                return Token{ .kind = .list_start };
            },
            ')' => {
                self.index += 1;
                return Token{ .kind = .list_end };
            },
            '"' => return Token{ .kind = .quoted, .value = try self.readQuoted() },
            '{' => return Token{ .kind = .literal, .value = try self.readLiteral() },
            else => {
                const atom = self.readAtom();
                if (std.ascii.eqlIgnoreCase(atom, "NIL")) {
                    return Token{ .kind = .nil };
                }
                return Token{ .kind = .atom, .value = atom };
            },
        }
    }

    fn skipSpaces(self: *Decoder) void {
        while (self.index < self.input.len and (self.input[self.index] == ' ' or self.input[self.index] == '\r' or self.input[self.index] == '\n')) : (self.index += 1) {}
    }

    fn readQuoted(self: *Decoder) ![]const u8 {
        self.index += 1;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        while (self.index < self.input.len) : (self.index += 1) {
            const byte = self.input[self.index];
            if (byte == '"') {
                self.index += 1;
                return out.toOwnedSlice(self.allocator);
            }
            if (byte == '\\' and self.index + 1 < self.input.len) {
                self.index += 1;
                try out.append(self.allocator, self.input[self.index]);
            } else {
                try out.append(self.allocator, byte);
            }
        }
        return error.UnterminatedQuotedString;
    }

    fn readLiteral(self: *Decoder) ![]const u8 {
        const start = self.index + 1;
        const close = std.mem.indexOfScalarPos(u8, self.input, start, '}') orelse return error.InvalidLiteral;
        const len = try std.fmt.parseInt(usize, self.input[start..close], 10);
        self.index = close + 1;
        if (self.index + 2 > self.input.len or !std.mem.eql(u8, self.input[self.index .. self.index + 2], "\r\n")) {
            return error.InvalidLiteral;
        }
        self.index += 2;
        if (self.index + len > self.input.len) return error.InvalidLiteral;
        const value = try self.allocator.dupe(u8, self.input[self.index .. self.index + len]);
        self.index += len;
        return value;
    }

    fn readAtom(self: *Decoder) []const u8 {
        const start = self.index;
        while (self.index < self.input.len) : (self.index += 1) {
            const byte = self.input[self.index];
            if (byte == ' ' or byte == '(' or byte == ')' or byte == '\r' or byte == '\n') break;
        }
        return self.input[start..self.index];
    }
};
