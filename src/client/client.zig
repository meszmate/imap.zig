const std = @import("std");
const imap = @import("../root.zig");
const wire = @import("../wire/root.zig");

pub const Client = struct {
    allocator: std.mem.Allocator,
    transport: wire.Transport,
    reader: wire.LineReader,
    capabilities: imap.CapabilitySet,
    state: imap.ConnState = .not_authenticated,
    next_tag: u32 = 1,
    owned_stream: ?*std.net.Stream = null,

    pub fn init(allocator: std.mem.Allocator, transport: wire.Transport) !Client {
        var client = Client{
            .allocator = allocator,
            .transport = transport,
            .reader = wire.LineReader.init(allocator, transport),
            .capabilities = imap.CapabilitySet.init(allocator),
        };
        try client.readGreeting();
        return client;
    }

    pub fn connectTcp(allocator: std.mem.Allocator, host: []const u8, port: u16) !Client {
        const stream_ptr = try allocator.create(std.net.Stream);
        errdefer allocator.destroy(stream_ptr);
        stream_ptr.* = try std.net.tcpConnectToHost(allocator, host, port);
        var client = try Client.init(allocator, wire.Transport.fromNetStream(stream_ptr));
        client.owned_stream = stream_ptr;
        return client;
    }

    pub fn deinit(self: *Client) void {
        self.capabilities.deinit();
        self.transport.close() catch {};
        if (self.owned_stream) |stream| {
            self.allocator.destroy(stream);
        }
        self.* = undefined;
    }

    pub fn capability(self: *Client) ![]const []const u8 {
        var result = try self.runSimple("CAPABILITY");
        defer result.deinit();
        try self.ensureOk(&result);
        try self.capabilitiesFromResult(&result);
        return self.capabilities.slice();
    }

    pub fn noop(self: *Client) !void {
        var result = try self.runSimple("NOOP");
        defer result.deinit();
        try self.ensureOk(&result);
    }

    pub fn logout(self: *Client) !void {
        var result = try self.runSimple("LOGOUT");
        defer result.deinit();
        try self.ensureOk(&result);
        self.state = .logout;
    }

    pub fn login(self: *Client, username: []const u8, password: []const u8) !void {
        var command: std.ArrayList(u8) = .empty;
        defer command.deinit(self.allocator);
        const writer = command.writer(self.allocator);
        try writer.writeAll("LOGIN ");
        try wire.writeQuoted(writer, username);
        try writer.writeByte(' ');
        try wire.writeQuoted(writer, password);

        var result = try self.runCommand(command.items, null);
        defer result.deinit();
        try self.ensureOk(&result);
        self.state = .authenticated;
    }

    pub fn select(self: *Client, mailbox: []const u8) !imap.SelectData {
        return self.selectLike("SELECT", mailbox, false);
    }

    pub fn examine(self: *Client, mailbox: []const u8) !imap.SelectData {
        return self.selectLike("EXAMINE", mailbox, true);
    }

    pub fn list(self: *Client, reference: []const u8, pattern: []const u8) ![]imap.ListData {
        var command: std.ArrayList(u8) = .empty;
        defer command.deinit(self.allocator);
        const writer = command.writer(self.allocator);
        try writer.writeAll("LIST ");
        try wire.writeQuoted(writer, reference);
        try writer.writeByte(' ');
        try wire.writeQuoted(writer, pattern);

        var result = try self.runCommand(command.items, null);
        defer result.deinit();
        try self.ensureOk(&result);
        return parseListData(self.allocator, &result);
    }

    pub fn freeListData(self: *Client, items: []imap.ListData) void {
        for (items) |item| self.allocator.free(item.mailbox);
        self.allocator.free(items);
    }

    pub fn freeStatusData(self: *Client, data: *imap.StatusData) void {
        if (data.mailbox.len != 0) self.allocator.free(data.mailbox);
        data.* = undefined;
    }

    pub fn status(self: *Client, mailbox: []const u8, items: []const []const u8) !imap.StatusData {
        var command: std.ArrayList(u8) = .empty;
        defer command.deinit(self.allocator);
        const writer = command.writer(self.allocator);
        try writer.writeAll("STATUS ");
        try wire.writeQuoted(writer, mailbox);
        try writer.writeAll(" (");
        for (items, 0..) |item, index| {
            if (index != 0) try writer.writeByte(' ');
            try writer.writeAll(item);
        }
        try writer.writeByte(')');

        var result = try self.runCommand(command.items, null);
        defer result.deinit();
        try self.ensureOk(&result);
        return parseStatusData(self.allocator, &result);
    }

    pub fn append(self: *Client, mailbox: []const u8, bytes: []const u8) !imap.AppendData {
        var command: std.ArrayList(u8) = .empty;
        defer command.deinit(self.allocator);
        const writer = command.writer(self.allocator);
        try writer.writeAll("APPEND ");
        try wire.writeQuoted(writer, mailbox);
        try writer.print(" {{{d}}}", .{bytes.len});

        var result = try self.runCommand(command.items, bytes);
        defer result.deinit();
        try self.ensureOk(&result);
        return parseAppendData(&result);
    }

    pub fn search(self: *Client, criteria: []const u8) ![]u32 {
        const command = try std.fmt.allocPrint(self.allocator, "SEARCH {s}", .{criteria});
        defer self.allocator.free(command);

        var result = try self.runCommand(command, null);
        defer result.deinit();
        try self.ensureOk(&result);
        return parseSearchData(self.allocator, &result);
    }

    pub fn fetchRaw(self: *Client, set: []const u8, items: []const u8) ![][]u8 {
        const command = try std.fmt.allocPrint(self.allocator, "FETCH {s} {s}", .{ set, items });
        defer self.allocator.free(command);

        var result = try self.runCommand(command, null);
        defer result.deinit();
        try self.ensureOk(&result);
        return cloneLines(self.allocator, result.untagged.items);
    }

    pub fn freeLines(self: *Client, lines: [][]u8) void {
        for (lines) |line| self.allocator.free(line);
        self.allocator.free(lines);
    }

    fn readGreeting(self: *Client) !void {
        const line = try self.reader.readLineAlloc();
        defer self.allocator.free(line);

        var greeting = try imap.parseStatusLine(self.allocator, line);
        defer imap.freeStatus(self.allocator, &greeting);

        switch (greeting.kind) {
            .ok => self.state = .not_authenticated,
            .preauth => self.state = .authenticated,
            .bye => return error.ConnectionRejected,
            else => return error.InvalidGreeting,
        }

        if (greeting.code) |code| {
            if (std.ascii.eqlIgnoreCase(code, "CAPABILITY")) {
                if (greeting.code_arg) |cap_text| {
                    try addCapabilitiesFromLine(&self.capabilities, cap_text);
                }
            }
        }
    }

    fn selectLike(self: *Client, verb: []const u8, mailbox: []const u8, read_only: bool) !imap.SelectData {
        var command: std.ArrayList(u8) = .empty;
        defer command.deinit(self.allocator);
        const writer = command.writer(self.allocator);
        try writer.writeAll(verb);
        try writer.writeByte(' ');
        try wire.writeQuoted(writer, mailbox);

        var result = try self.runCommand(command.items, null);
        defer result.deinit();
        try self.ensureOk(&result);
        self.state = .selected;
        var data = parseSelectData(mailbox, &result);
        data.read_only = read_only;
        return data;
    }

    fn runSimple(self: *Client, command: []const u8) !CommandResult {
        return self.runCommand(command, null);
    }

    fn runCommand(self: *Client, command: []const u8, literal: ?[]const u8) !CommandResult {
        const tag = try self.nextTagString();
        defer self.allocator.free(tag);

        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.allocator);
        const writer = line.writer(self.allocator);
        try writer.print("{s} {s}\r\n", .{ tag, command });
        try self.transport.writeAll(line.items);

        var result = CommandResult.init(self.allocator);
        errdefer result.deinit();

        var literal_sent = literal == null;
        while (true) {
            const response_line = try self.reader.readLineAlloc();
            errdefer self.allocator.free(response_line);

            if (!literal_sent and response_line.len > 0 and response_line[0] == '+') {
                self.allocator.free(response_line);
                try self.transport.writeAll(literal.?);
                try self.transport.writeAll("\r\n");
                literal_sent = true;
                continue;
            }

            if (std.mem.startsWith(u8, response_line, tag) and response_line.len > tag.len and response_line[tag.len] == ' ') {
                result.tagged = try imap.parseStatusLine(self.allocator, response_line);
                self.allocator.free(response_line);
                break;
            }

            try result.untagged.append(self.allocator, response_line);
        }

        return result;
    }

    fn ensureOk(self: *Client, result: *CommandResult) !void {
        _ = self;
        if (!result.tagged.isOk()) return error.CommandRejected;
    }

    fn capabilitiesFromResult(self: *Client, result: *CommandResult) !void {
        for (result.untagged.items) |line| {
            if (std.mem.startsWith(u8, line, "* CAPABILITY ")) {
                try addCapabilitiesFromLine(&self.capabilities, line["* CAPABILITY ".len..]);
            }
        }
    }

    fn nextTagString(self: *Client) ![]u8 {
        const tag = try std.fmt.allocPrint(self.allocator, "A{d:0>4}", .{self.next_tag});
        self.next_tag += 1;
        return tag;
    }
};

pub const CommandResult = struct {
    allocator: std.mem.Allocator,
    tagged: imap.StatusResponse = .{ .kind = .bad },
    untagged: std.ArrayList([]u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) CommandResult {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CommandResult) void {
        if (self.untagged.items.len > 0 or self.tagged.text.len > 0 or self.tagged.tag != null or self.tagged.code != null or self.tagged.code_arg != null) {
            for (self.untagged.items) |line| self.allocator.free(line);
            self.untagged.deinit(self.allocator);
            if (self.tagged.tag != null or self.tagged.code != null or self.tagged.code_arg != null or self.tagged.text.len > 0) {
                imap.freeStatus(self.allocator, &self.tagged);
            }
        }
    }
};

pub const Placeholder = Client;

fn addCapabilitiesFromLine(set: *imap.CapabilitySet, text: []const u8) !void {
    var it = std.mem.tokenizeAny(u8, text, " ");
    while (it.next()) |cap| {
        try set.add(cap);
    }
}

fn parseSelectData(mailbox: []const u8, result: *const CommandResult) imap.SelectData {
    var data = imap.SelectData{
        .mailbox = mailbox,
    };
    for (result.untagged.items) |line| {
        if (std.mem.startsWith(u8, line, "* ")) {
            const payload = line[2..];
            if (std.mem.endsWith(u8, payload, " EXISTS")) {
                data.exists = std.fmt.parseInt(u32, payload[0 .. payload.len - " EXISTS".len], 10) catch data.exists;
            } else if (std.mem.endsWith(u8, payload, " RECENT")) {
                data.recent = std.fmt.parseInt(u32, payload[0 .. payload.len - " RECENT".len], 10) catch data.recent;
            } else if (std.mem.startsWith(u8, payload, "OK [UIDVALIDITY ")) {
                data.uid_validity = parseBracketNumber(payload, "OK [UIDVALIDITY ");
            } else if (std.mem.startsWith(u8, payload, "OK [UIDNEXT ")) {
                data.uid_next = parseBracketNumber(payload, "OK [UIDNEXT ");
            } else if (std.mem.startsWith(u8, payload, "OK [UNSEEN ")) {
                data.unseen = parseBracketNumber(payload, "OK [UNSEEN ");
            }
        }
    }
    return data;
}

fn parseListData(allocator: std.mem.Allocator, result: *const CommandResult) ![]imap.ListData {
    var entries: std.ArrayList(imap.ListData) = .empty;
    errdefer {
        for (entries.items) |item| allocator.free(item.mailbox);
        entries.deinit(allocator);
    }

    for (result.untagged.items) |line| {
        if (!std.mem.startsWith(u8, line, "* LIST ")) continue;
        const first_quote = std.mem.indexOfScalar(u8, line, '"') orelse continue;
        const second_quote = std.mem.indexOfScalarPos(u8, line, first_quote + 1, '"') orelse continue;
        const third_quote = std.mem.indexOfScalarPos(u8, line, second_quote + 1, '"') orelse continue;
        const fourth_quote = std.mem.indexOfScalarPos(u8, line, third_quote + 1, '"') orelse continue;

        try entries.append(allocator, .{
            .delimiter = if (second_quote > first_quote + 1) line[first_quote + 1] else null,
            .mailbox = try allocator.dupe(u8, line[third_quote + 1 .. fourth_quote]),
        });
    }

    return entries.toOwnedSlice(allocator);
}

fn parseStatusData(allocator: std.mem.Allocator, result: *const CommandResult) !imap.StatusData {
    for (result.untagged.items) |line| {
        if (!std.mem.startsWith(u8, line, "* STATUS ")) continue;
        const open = std.mem.indexOfScalar(u8, line, '(') orelse return error.InvalidStatusResponse;
        const close = std.mem.lastIndexOfScalar(u8, line, ')') orelse return error.InvalidStatusResponse;
        var data = imap.StatusData{};
        data.mailbox = try allocator.dupe(u8, std.mem.trim(u8, line["* STATUS ".len..open], "\" "));

        var it = std.mem.tokenizeAny(u8, line[open + 1 .. close], " ");
        while (it.next()) |item| {
            const value = it.next() orelse break;
            if (std.ascii.eqlIgnoreCase(item, "MESSAGES")) data.messages = try std.fmt.parseInt(u32, value, 10);
            if (std.ascii.eqlIgnoreCase(item, "RECENT")) data.recent = try std.fmt.parseInt(u32, value, 10);
            if (std.ascii.eqlIgnoreCase(item, "UNSEEN")) data.unseen = try std.fmt.parseInt(u32, value, 10);
            if (std.ascii.eqlIgnoreCase(item, "UIDNEXT")) data.uid_next = try std.fmt.parseInt(u32, value, 10);
            if (std.ascii.eqlIgnoreCase(item, "UIDVALIDITY")) data.uid_validity = try std.fmt.parseInt(u32, value, 10);
        }
        return data;
    }
    return error.InvalidStatusResponse;
}

fn parseAppendData(result: *const CommandResult) imap.AppendData {
    var data = imap.AppendData{};
    if (result.tagged.code) |code| {
        if (std.ascii.eqlIgnoreCase(code, "APPENDUID")) {
            if (result.tagged.code_arg) |arg| {
                var it = std.mem.tokenizeAny(u8, arg, " ");
                if (it.next()) |uid_validity| data.uid_validity = std.fmt.parseInt(u32, uid_validity, 10) catch null;
                if (it.next()) |uid| data.uid = std.fmt.parseInt(imap.UID, uid, 10) catch null;
            }
        }
    }
    return data;
}

fn parseSearchData(allocator: std.mem.Allocator, result: *const CommandResult) ![]u32 {
    for (result.untagged.items) |line| {
        if (!std.mem.startsWith(u8, line, "* SEARCH")) continue;
        const suffix = std.mem.trimLeft(u8, line["* SEARCH".len..], " ");
        if (suffix.len == 0) return allocator.alloc(u32, 0);

        var values: std.ArrayList(u32) = .empty;
        errdefer values.deinit(allocator);
        var it = std.mem.tokenizeAny(u8, suffix, " ");
        while (it.next()) |token| {
            try values.append(allocator, try std.fmt.parseInt(u32, token, 10));
        }
        return values.toOwnedSlice(allocator);
    }
    return error.InvalidSearchResponse;
}

fn parseBracketNumber(line: []const u8, prefix: []const u8) ?u32 {
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const close = std.mem.indexOfScalar(u8, line, ']') orelse return null;
    return std.fmt.parseInt(u32, line[prefix.len..close], 10) catch null;
}

fn cloneLines(allocator: std.mem.Allocator, lines: []const []u8) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |line| allocator.free(line);
        out.deinit(allocator);
    }
    for (lines) |line| {
        try out.append(allocator, try allocator.dupe(u8, line));
    }
    return out.toOwnedSlice(allocator);
}
