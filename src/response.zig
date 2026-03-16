const std = @import("std");

pub const StatusKind = enum {
    ok,
    no,
    bad,
    bye,
    preauth,
};

pub const StatusResponse = struct {
    tag: ?[]const u8 = null,
    kind: StatusKind,
    code: ?[]const u8 = null,
    code_arg: ?[]const u8 = null,
    text: []const u8 = "",

    pub fn isOk(self: StatusResponse) bool {
        return self.kind == .ok or self.kind == .preauth;
    }
};

pub fn parseStatusLine(allocator: std.mem.Allocator, line: []const u8) !StatusResponse {
    if (line.len == 0) return error.InvalidStatusLine;

    var status = StatusResponse{
        .kind = .bad,
    };

    var rest = line;
    if (rest[0] == '*') {
        rest = std.mem.trimLeft(u8, rest[1..], " ");
    } else {
        const first_space = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.InvalidStatusLine;
        status.tag = try allocator.dupe(u8, rest[0..first_space]);
        rest = std.mem.trimLeft(u8, rest[first_space + 1 ..], " ");
    }

    const kind_token, const after_kind = nextToken(rest) orelse return error.InvalidStatusLine;
    status.kind = parseKind(kind_token) orelse return error.InvalidStatusLine;
    rest = std.mem.trimLeft(u8, after_kind, " ");

    if (rest.len > 0 and rest[0] == '[') {
        const close = std.mem.indexOfScalar(u8, rest, ']') orelse return error.InvalidStatusLine;
        const code_inner = rest[1..close];
        if (std.mem.indexOfScalar(u8, code_inner, ' ')) |space| {
            status.code = try allocator.dupe(u8, code_inner[0..space]);
            status.code_arg = try allocator.dupe(u8, std.mem.trimLeft(u8, code_inner[space + 1 ..], " "));
        } else {
            status.code = try allocator.dupe(u8, code_inner);
        }
        rest = std.mem.trimLeft(u8, rest[close + 1 ..], " ");
    }

    status.text = try allocator.dupe(u8, rest);
    return status;
}

pub fn freeStatus(allocator: std.mem.Allocator, response: *StatusResponse) void {
    if (response.tag) |tag| allocator.free(tag);
    if (response.code) |code| allocator.free(code);
    if (response.code_arg) |code_arg| allocator.free(code_arg);
    allocator.free(response.text);
    response.* = undefined;
}

fn nextToken(input: []const u8) ?struct { []const u8, []const u8 } {
    if (input.len == 0) return null;
    if (std.mem.indexOfScalar(u8, input, ' ')) |space| {
        return .{ input[0..space], input[space + 1 ..] };
    }
    return .{ input, "" };
}

fn parseKind(token: []const u8) ?StatusKind {
    if (std.ascii.eqlIgnoreCase(token, "OK")) return .ok;
    if (std.ascii.eqlIgnoreCase(token, "NO")) return .no;
    if (std.ascii.eqlIgnoreCase(token, "BAD")) return .bad;
    if (std.ascii.eqlIgnoreCase(token, "BYE")) return .bye;
    if (std.ascii.eqlIgnoreCase(token, "PREAUTH")) return .preauth;
    return null;
}
