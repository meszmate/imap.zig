const std = @import("std");
const response = @import("../response.zig");
const wire = @import("../wire/root.zig");
const server_session = @import("session.zig");

pub const TokenKind = enum {
    atom,
    quoted,
    group,
};

pub const Token = struct {
    value: []const u8,
    kind: TokenKind,
};

pub const Command = struct {
    allocator: std.mem.Allocator,
    tag: []u8,
    name: []u8,
    args: [][]u8,
    uid_mode: bool = false,

    pub fn deinit(self: *Command) void {
        self.allocator.free(self.tag);
        self.allocator.free(self.name);
        for (self.args) |arg| self.allocator.free(arg);
        self.allocator.free(self.args);
        self.* = undefined;
    }
};

pub const Conn = struct {
    allocator: std.mem.Allocator,
    transport: wire.Transport,
    reader: wire.LineReader,
    session: server_session.SessionState = .{},

    pub fn init(allocator: std.mem.Allocator, transport: wire.Transport) Conn {
        return .{
            .allocator = allocator,
            .transport = transport,
            .reader = wire.LineReader.init(allocator, transport),
        };
    }

    pub fn writeGreeting(self: *Conn, capabilities: []const u8) !void {
        try self.transport.print("* OK [CAPABILITY {s}] imap.zig ready\r\n", .{capabilities});
    }

    pub fn writeUntagged(self: *Conn, line: []const u8) !void {
        try self.transport.print("* {s}\r\n", .{line});
    }

    pub fn writeTagged(self: *Conn, tag: []const u8, kind: response.StatusKind, code: ?[]const u8, text: []const u8) !void {
        const kind_text = switch (kind) {
            .ok => "OK",
            .no => "NO",
            .bad => "BAD",
            .bye => "BYE",
            .preauth => "PREAUTH",
        };
        if (code) |code_text| {
            try self.transport.print("{s} {s} [{s}] {s}\r\n", .{ tag, kind_text, code_text, text });
        } else {
            try self.transport.print("{s} {s} {s}\r\n", .{ tag, kind_text, text });
        }
    }

    pub fn readCommandAlloc(self: *Conn) !?Command {
        const line = self.reader.readLineAlloc() catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return err,
        };
        defer self.allocator.free(line);

        if (line.len == 0) return null;

        var tokens = try tokenizeLine(self.allocator, line);
        defer tokens.deinit(self.allocator);
        if (tokens.items.len < 2) return error.MalformedCommand;

        var command_name = tokens.items[1].value;
        var args = tokens.items[2..];
        var uid_mode = false;
        if (std.ascii.eqlIgnoreCase(command_name, "UID")) {
            if (args.len == 0) return error.MalformedCommand;
            uid_mode = true;
            command_name = args[0].value;
            args = args[1..];
        }

        var owned_args = try self.allocator.alloc([]u8, args.len);
        var populated: usize = 0;
        errdefer {
            for (owned_args[0..populated]) |arg| self.allocator.free(arg);
            self.allocator.free(owned_args);
        }
        for (args, 0..) |arg, index| {
            owned_args[index] = try self.allocator.dupe(u8, arg.value);
            populated += 1;
        }

        return .{
            .allocator = self.allocator,
            .tag = try self.allocator.dupe(u8, tokens.items[0].value),
            .name = try self.allocator.dupe(u8, command_name),
            .args = owned_args,
            .uid_mode = uid_mode,
        };
    }
};

pub fn tokenizeLine(allocator: std.mem.Allocator, line: []const u8) !std.ArrayList(Token) {
    var tokens: std.ArrayList(Token) = .empty;
    errdefer tokens.deinit(allocator);

    var i: usize = 0;
    while (i < line.len) {
        while (i < line.len and line[i] == ' ') : (i += 1) {}
        if (i >= line.len) break;

        if (line[i] == '"') {
            const start = i + 1;
            i += 1;
            while (i < line.len and line[i] != '"') : (i += 1) {
                if (line[i] == '\\' and i + 1 < line.len) i += 1;
            }
            if (i >= line.len) return error.UnterminatedQuotedString;
            try tokens.append(allocator, .{ .value = line[start..i], .kind = .quoted });
            i += 1;
            continue;
        }

        if (line[i] == '(') {
            const start = i + 1;
            var depth: usize = 1;
            i += 1;
            while (i < line.len and depth > 0) : (i += 1) {
                if (line[i] == '(') depth += 1 else if (line[i] == ')') depth -= 1;
            }
            if (depth != 0) return error.UnterminatedGroup;
            try tokens.append(allocator, .{ .value = line[start .. i - 1], .kind = .group });
            continue;
        }

        const start = i;
        while (i < line.len and line[i] != ' ') : (i += 1) {}
        try tokens.append(allocator, .{ .value = line[start..i], .kind = .atom });
    }

    return tokens;
}
