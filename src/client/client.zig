const std = @import("std");
const imap = @import("../root.zig");
const wire = @import("../wire/root.zig");
const auth = @import("../auth/root.zig");

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

    pub fn authenticatePlain(self: *Client, username: []const u8, password: []const u8) !void {
        var start = try self.runAuthenticate("PLAIN", null);
        defer start.deinit();
        const response = try auth.plain.initialResponseAlloc(self.allocator, "", username, password);
        defer self.allocator.free(response);
        try self.transport.writeAll(response);
        try self.transport.writeAll("\r\n");
        try self.finishAuthenticate(&start.result);
    }

    pub fn authenticateExternal(self: *Client, authzid: []const u8) !void {
        var start = try self.runAuthenticate("EXTERNAL", null);
        defer start.deinit();
        const response = try auth.external.initialResponseAlloc(self.allocator, authzid);
        defer self.allocator.free(response);
        try self.transport.writeAll(response);
        try self.transport.writeAll("\r\n");
        try self.finishAuthenticate(&start.result);
    }

    pub fn authenticateLogin(self: *Client, username: []const u8, password: []const u8) !void {
        var start = try self.runAuthenticate("LOGIN", null);
        defer start.deinit();
        const user_b64 = try auth.login.encodeAlloc(self.allocator, username);
        defer self.allocator.free(user_b64);
        try self.transport.writeAll(user_b64);
        try self.transport.writeAll("\r\n");
        const password_prompt = try self.reader.readLineAlloc();
        defer self.allocator.free(password_prompt);
        if (password_prompt.len == 0 or password_prompt[0] != '+') return error.InvalidAuthenticateContinuation;
        const pass_b64 = try auth.login.encodeAlloc(self.allocator, password);
        defer self.allocator.free(pass_b64);
        try self.transport.writeAll(pass_b64);
        try self.transport.writeAll("\r\n");
        try self.finishAuthenticate(&start.result);
    }

    pub fn authenticateAnonymous(self: *Client, trace: []const u8) !void {
        var start = try self.runAuthenticate("ANONYMOUS", null);
        defer start.deinit();
        const response = try auth.anonymous.initialResponseAlloc(self.allocator, trace);
        defer self.allocator.free(response);
        try self.transport.writeAll(response);
        try self.transport.writeAll("\r\n");
        try self.finishAuthenticate(&start.result);
    }

    pub fn authenticateCramMd5(self: *Client, username: []const u8, password: []const u8) !void {
        var start = try self.runAuthenticate("CRAM-MD5", null);
        defer start.deinit();
        const response = try auth.crammd5.responseAlloc(self.allocator, username, password, std.mem.trim(u8, start.continuation, " "));
        defer self.allocator.free(response);
        try self.transport.writeAll(response);
        try self.transport.writeAll("\r\n");
        try self.finishAuthenticate(&start.result);
    }

    pub fn authenticateXOAuth2(self: *Client, user: []const u8, access_token: []const u8) !void {
        var start = try self.runAuthenticate("XOAUTH2", null);
        defer start.deinit();
        const response = try auth.xoauth2.initialResponseAlloc(self.allocator, user, access_token);
        defer self.allocator.free(response);
        try self.transport.writeAll(response);
        try self.transport.writeAll("\r\n");
        try self.finishAuthenticate(&start.result);
    }

    pub fn authenticateOAuthBearer(self: *Client, user: []const u8, access_token: []const u8, host: ?[]const u8, port: ?u16) !void {
        var start = try self.runAuthenticate("OAUTHBEARER", null);
        defer start.deinit();
        const response = try auth.oauthbearer.initialResponseAlloc(self.allocator, user, access_token, host, port);
        defer self.allocator.free(response);
        try self.transport.writeAll(response);
        try self.transport.writeAll("\r\n");
        try self.finishAuthenticate(&start.result);
    }

    pub fn select(self: *Client, mailbox: []const u8) !imap.SelectData {
        return self.selectLike("SELECT", mailbox, false);
    }

    pub fn examine(self: *Client, mailbox: []const u8) !imap.SelectData {
        return self.selectLike("EXAMINE", mailbox, true);
    }

    pub fn list(self: *Client, reference: []const u8, pattern: []const u8) ![]imap.ListData {
        return self.listLike("LIST", reference, pattern);
    }

    pub fn lsub(self: *Client, reference: []const u8, pattern: []const u8) ![]imap.ListData {
        return self.listLike("LSUB", reference, pattern);
    }

    pub fn create(self: *Client, mailbox: []const u8) !void {
        try self.simpleMailboxCommand("CREATE", mailbox);
    }

    pub fn delete(self: *Client, mailbox: []const u8) !void {
        try self.simpleMailboxCommand("DELETE", mailbox);
    }

    pub fn subscribe(self: *Client, mailbox: []const u8) !void {
        try self.simpleMailboxCommand("SUBSCRIBE", mailbox);
    }

    pub fn unsubscribe(self: *Client, mailbox: []const u8) !void {
        try self.simpleMailboxCommand("UNSUBSCRIBE", mailbox);
    }

    pub fn rename(self: *Client, mailbox: []const u8, new_mailbox: []const u8) !void {
        var command: std.ArrayList(u8) = .empty;
        defer command.deinit(self.allocator);
        const writer = command.writer(self.allocator);
        try writer.writeAll("RENAME ");
        try wire.writeQuoted(writer, mailbox);
        try writer.writeByte(' ');
        try wire.writeQuoted(writer, new_mailbox);

        var result = try self.runCommand(command.items, null);
        defer result.deinit();
        try self.ensureOk(&result);
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

    pub fn namespace(self: *Client) ![][]u8 {
        var result = try self.runSimple("NAMESPACE");
        defer result.deinit();
        try self.ensureOk(&result);
        return cloneLines(self.allocator, result.untagged.items);
    }

    pub fn id(self: *Client, fields: []const [2][]const u8) ![][]u8 {
        var command: std.ArrayList(u8) = .empty;
        defer command.deinit(self.allocator);
        const writer = command.writer(self.allocator);
        try writer.writeAll("ID ");
        if (fields.len == 0) {
            try writer.writeAll("NIL");
        } else {
            try writer.writeByte('(');
            for (fields, 0..) |field, index| {
                if (index != 0) try writer.writeByte(' ');
                try wire.writeQuoted(writer, field[0]);
                try writer.writeByte(' ');
                try wire.writeQuoted(writer, field[1]);
            }
            try writer.writeByte(')');
        }

        var result = try self.runCommand(command.items, null);
        defer result.deinit();
        try self.ensureOk(&result);
        return cloneLines(self.allocator, result.untagged.items);
    }

    pub fn enable(self: *Client, capabilities: []const []const u8) !void {
        var command: std.ArrayList(u8) = .empty;
        defer command.deinit(self.allocator);
        const writer = command.writer(self.allocator);
        try writer.writeAll("ENABLE");
        for (capabilities) |cap_name| {
            try writer.writeByte(' ');
            try writer.writeAll(cap_name);
        }

        var result = try self.runCommand(command.items, null);
        defer result.deinit();
        try self.ensureOk(&result);
    }

    pub fn idleOnce(self: *Client) ![][]u8 {
        const tag = try self.nextTagString();
        defer self.allocator.free(tag);

        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.allocator);
        try line.writer(self.allocator).print("{s} IDLE\r\n", .{tag});
        try self.transport.writeAll(line.items);

        const cont = try self.reader.readLineAlloc();
        defer self.allocator.free(cont);
        if (cont.len == 0 or cont[0] != '+') return error.InvalidIdleContinuation;

        var out: std.ArrayList([]u8) = .empty;
        errdefer {
            for (out.items) |item| self.allocator.free(item);
            out.deinit(self.allocator);
        }

        while (true) {
            const response_line = try self.reader.readLineAlloc();
            errdefer self.allocator.free(response_line);
            if (std.mem.startsWith(u8, response_line, "* ")) {
                try out.append(self.allocator, response_line);
                break;
            }
            self.allocator.free(response_line);
            break;
        }

        try self.transport.writeAll("DONE\r\n");
        const done_line = try self.reader.readLineAlloc();
        defer self.allocator.free(done_line);
        if (!std.mem.startsWith(u8, done_line, tag)) return error.InvalidIdleCompletion;

        return out.toOwnedSlice(self.allocator);
    }

    pub fn unselect(self: *Client) !void {
        var result = try self.runSimple("UNSELECT");
        defer result.deinit();
        try self.ensureOk(&result);
        self.state = .authenticated;
    }

    pub fn closeMailbox(self: *Client) !void {
        var result = try self.runSimple("CLOSE");
        defer result.deinit();
        try self.ensureOk(&result);
        self.state = .authenticated;
    }

    pub fn expunge(self: *Client) ![][]u8 {
        var result = try self.runSimple("EXPUNGE");
        defer result.deinit();
        try self.ensureOk(&result);
        return cloneLines(self.allocator, result.untagged.items);
    }

    pub fn copy(self: *Client, set: []const u8, destination: []const u8) !imap.CopyData {
        return self.copyLike("COPY", set, destination);
    }

    pub fn move(self: *Client, set: []const u8, destination: []const u8) !imap.CopyData {
        return self.copyLike("MOVE", set, destination);
    }

    pub fn freeCopyData(self: *Client, data: *imap.CopyData) void {
        if (data.source_uids.len != 0) self.allocator.free(data.source_uids);
        if (data.dest_uids.len != 0) self.allocator.free(data.dest_uids);
        data.* = undefined;
    }

    pub fn storeRaw(self: *Client, set: []const u8, operation: []const u8, flags: []const []const u8) ![][]u8 {
        var command: std.ArrayList(u8) = .empty;
        defer command.deinit(self.allocator);
        const writer = command.writer(self.allocator);
        try writer.print("STORE {s} {s} (", .{ set, operation });
        for (flags, 0..) |flag, index| {
            if (index != 0) try writer.writeByte(' ');
            try writer.writeAll(flag);
        }
        try writer.writeByte(')');

        var result = try self.runCommand(command.items, null);
        defer result.deinit();
        try self.ensureOk(&result);
        return cloneLines(self.allocator, result.untagged.items);
    }

    pub fn sort(self: *Client, criteria: []const imap.SortCriterion, charset: []const u8, search_criteria: []const u8) ![]u32 {
        var command: std.ArrayList(u8) = .empty;
        defer command.deinit(self.allocator);
        const writer = command.writer(self.allocator);
        try writer.writeAll("SORT (");
        for (criteria, 0..) |c, i| {
            if (i != 0) try writer.writeByte(' ');
            if (c.reverse) try writer.writeAll("REVERSE ");
            try writer.writeAll(c.key.label());
        }
        try writer.print(") {s} {s}", .{ charset, search_criteria });

        var result = try self.runCommand(command.items, null);
        defer result.deinit();
        try self.ensureOk(&result);
        return parseSortData(self.allocator, &result);
    }

    pub fn threadCmd(self: *Client, algorithm: imap.ThreadAlgorithm, charset: []const u8, search_criteria: []const u8) ![][]u8 {
        var command: std.ArrayList(u8) = .empty;
        defer command.deinit(self.allocator);
        const writer = command.writer(self.allocator);
        try writer.print("THREAD {s} {s} {s}", .{ algorithm.label(), charset, search_criteria });

        var result = try self.runCommand(command.items, null);
        defer result.deinit();
        try self.ensureOk(&result);
        return cloneLines(self.allocator, result.untagged.items);
    }

    pub fn getAcl(self: *Client, mailbox: []const u8) ![][]u8 {
        var command: std.ArrayList(u8) = .empty;
        defer command.deinit(self.allocator);
        const writer = command.writer(self.allocator);
        try writer.writeAll("GETACL ");
        try wire.writeQuoted(writer, mailbox);

        var result = try self.runCommand(command.items, null);
        defer result.deinit();
        try self.ensureOk(&result);
        return cloneLines(self.allocator, result.untagged.items);
    }

    pub fn setAcl(self: *Client, mailbox: []const u8, identifier: []const u8, rights: []const u8) !void {
        var command: std.ArrayList(u8) = .empty;
        defer command.deinit(self.allocator);
        const writer = command.writer(self.allocator);
        try writer.writeAll("SETACL ");
        try wire.writeQuoted(writer, mailbox);
        try writer.print(" {s} {s}", .{ identifier, rights });

        var result = try self.runCommand(command.items, null);
        defer result.deinit();
        try self.ensureOk(&result);
    }

    pub fn deleteAcl(self: *Client, mailbox: []const u8, identifier: []const u8) !void {
        var command: std.ArrayList(u8) = .empty;
        defer command.deinit(self.allocator);
        const writer = command.writer(self.allocator);
        try writer.writeAll("DELETEACL ");
        try wire.writeQuoted(writer, mailbox);
        try writer.print(" {s}", .{identifier});

        var result = try self.runCommand(command.items, null);
        defer result.deinit();
        try self.ensureOk(&result);
    }

    pub fn listRights(self: *Client, mailbox: []const u8, identifier: []const u8) ![][]u8 {
        var command: std.ArrayList(u8) = .empty;
        defer command.deinit(self.allocator);
        const writer = command.writer(self.allocator);
        try writer.writeAll("LISTRIGHTS ");
        try wire.writeQuoted(writer, mailbox);
        try writer.print(" {s}", .{identifier});

        var result = try self.runCommand(command.items, null);
        defer result.deinit();
        try self.ensureOk(&result);
        return cloneLines(self.allocator, result.untagged.items);
    }

    pub fn myRights(self: *Client, mailbox: []const u8) ![][]u8 {
        var command: std.ArrayList(u8) = .empty;
        defer command.deinit(self.allocator);
        const writer = command.writer(self.allocator);
        try writer.writeAll("MYRIGHTS ");
        try wire.writeQuoted(writer, mailbox);

        var result = try self.runCommand(command.items, null);
        defer result.deinit();
        try self.ensureOk(&result);
        return cloneLines(self.allocator, result.untagged.items);
    }

    pub fn getQuota(self: *Client, root: []const u8) ![][]u8 {
        var command: std.ArrayList(u8) = .empty;
        defer command.deinit(self.allocator);
        const writer = command.writer(self.allocator);
        try writer.writeAll("GETQUOTA ");
        try wire.writeQuoted(writer, root);

        var result = try self.runCommand(command.items, null);
        defer result.deinit();
        try self.ensureOk(&result);
        return cloneLines(self.allocator, result.untagged.items);
    }

    pub fn setQuota(self: *Client, root: []const u8, resources: []const u8) !void {
        var command: std.ArrayList(u8) = .empty;
        defer command.deinit(self.allocator);
        const writer = command.writer(self.allocator);
        try writer.writeAll("SETQUOTA ");
        try wire.writeQuoted(writer, root);
        try writer.print(" ({s})", .{resources});

        var result = try self.runCommand(command.items, null);
        defer result.deinit();
        try self.ensureOk(&result);
    }

    pub fn getQuotaRoot(self: *Client, mailbox: []const u8) ![][]u8 {
        var command: std.ArrayList(u8) = .empty;
        defer command.deinit(self.allocator);
        const writer = command.writer(self.allocator);
        try writer.writeAll("GETQUOTAROOT ");
        try wire.writeQuoted(writer, mailbox);

        var result = try self.runCommand(command.items, null);
        defer result.deinit();
        try self.ensureOk(&result);
        return cloneLines(self.allocator, result.untagged.items);
    }

    pub fn getMetadata(self: *Client, mailbox: []const u8, entries: []const []const u8) ![][]u8 {
        var command: std.ArrayList(u8) = .empty;
        defer command.deinit(self.allocator);
        const writer = command.writer(self.allocator);
        try writer.writeAll("GETMETADATA ");
        try wire.writeQuoted(writer, mailbox);
        try writer.writeAll(" (");
        for (entries, 0..) |entry, i| {
            if (i != 0) try writer.writeByte(' ');
            try wire.writeQuoted(writer, entry);
        }
        try writer.writeByte(')');

        var result = try self.runCommand(command.items, null);
        defer result.deinit();
        try self.ensureOk(&result);
        return cloneLines(self.allocator, result.untagged.items);
    }

    pub fn setMetadata(self: *Client, mailbox: []const u8, entries: []const [2][]const u8) !void {
        var command: std.ArrayList(u8) = .empty;
        defer command.deinit(self.allocator);
        const writer = command.writer(self.allocator);
        try writer.writeAll("SETMETADATA ");
        try wire.writeQuoted(writer, mailbox);
        try writer.writeAll(" (");
        for (entries, 0..) |entry, i| {
            if (i != 0) try writer.writeByte(' ');
            try wire.writeQuoted(writer, entry[0]);
            try writer.writeByte(' ');
            try wire.writeQuoted(writer, entry[1]);
        }
        try writer.writeByte(')');

        var result = try self.runCommand(command.items, null);
        defer result.deinit();
        try self.ensureOk(&result);
    }

    pub fn compress(self: *Client) !void {
        var result = try self.runSimple("COMPRESS DEFLATE");
        defer result.deinit();
        try self.ensureOk(&result);
    }

    pub fn unauthenticate(self: *Client) !void {
        var result = try self.runSimple("UNAUTHENTICATE");
        defer result.deinit();
        try self.ensureOk(&result);
        self.state = .not_authenticated;
    }

    pub fn replaceMsg(self: *Client, set: []const u8, mailbox: []const u8, bytes: []const u8) !imap.AppendData {
        var command: std.ArrayList(u8) = .empty;
        defer command.deinit(self.allocator);
        const writer = command.writer(self.allocator);
        try writer.writeAll("REPLACE ");
        try writer.writeAll(set);
        try writer.writeByte(' ');
        try wire.writeQuoted(writer, mailbox);
        try writer.print(" {{{d}}}", .{bytes.len});

        var result = try self.runCommand(command.items, bytes);
        defer result.deinit();
        try self.ensureOk(&result);
        return parseAppendData(&result);
    }

    pub fn starttls(self: *Client) !void {
        var result = try self.runSimple("STARTTLS");
        defer result.deinit();
        try self.ensureOk(&result);
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

    fn runAuthenticate(self: *Client, mechanism: []const u8, initial: ?[]const u8) !AuthenticateStart {
        var command: std.ArrayList(u8) = .empty;
        defer command.deinit(self.allocator);
        const writer = command.writer(self.allocator);
        try writer.writeAll("AUTHENTICATE ");
        try writer.writeAll(mechanism);
        if (initial) |value| {
            try writer.writeByte(' ');
            try writer.writeAll(value);
        }
        const tag = try self.nextTagString();
        defer self.allocator.free(tag);

        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.allocator);
        try line.writer(self.allocator).print("{s} {s}\r\n", .{ tag, command.items });
        try self.transport.writeAll(line.items);

        const cont = try self.reader.readLineAlloc();
        if (cont.len == 0 or cont[0] != '+') {
            defer self.allocator.free(cont);
            return error.InvalidAuthenticateContinuation;
        }
        const trimmed = std.mem.trimLeft(u8, if (cont.len > 1) cont[1..] else "", " ");
        defer self.allocator.free(cont);
        return AuthenticateStart{
            .allocator = self.allocator,
            .continuation = try self.allocator.dupe(u8, trimmed),
            .result = .{
                .allocator = self.allocator,
                .tagged = .{ .kind = .bad, .tag = try self.allocator.dupe(u8, tag), .text = &.{} },
            },
        };
    }

    fn finishAuthenticate(self: *Client, result: *CommandResult) !void {
        const line = try self.reader.readLineAlloc();
        defer self.allocator.free(line);
        if (!std.mem.startsWith(u8, line, result.tagged.tag.?)) return error.InvalidAuthenticateCompletion;
        if (result.tagged.tag) |tag| self.allocator.free(tag);
        result.tagged = try imap.parseStatusLine(self.allocator, line);
        try self.ensureOk(result);
        self.state = .authenticated;
    }

    fn listLike(self: *Client, verb: []const u8, reference: []const u8, pattern: []const u8) ![]imap.ListData {
        var command: std.ArrayList(u8) = .empty;
        defer command.deinit(self.allocator);
        const writer = command.writer(self.allocator);
        try writer.writeAll(verb);
        try writer.writeByte(' ');
        try wire.writeQuoted(writer, reference);
        try writer.writeByte(' ');
        try wire.writeQuoted(writer, pattern);

        var result = try self.runCommand(command.items, null);
        defer result.deinit();
        try self.ensureOk(&result);
        return parseListData(self.allocator, &result);
    }

    fn simpleMailboxCommand(self: *Client, verb: []const u8, mailbox: []const u8) !void {
        var command: std.ArrayList(u8) = .empty;
        defer command.deinit(self.allocator);
        const writer = command.writer(self.allocator);
        try writer.writeAll(verb);
        try writer.writeByte(' ');
        try wire.writeQuoted(writer, mailbox);

        var result = try self.runCommand(command.items, null);
        defer result.deinit();
        try self.ensureOk(&result);
    }

    fn copyLike(self: *Client, verb: []const u8, set: []const u8, destination: []const u8) !imap.CopyData {
        var command: std.ArrayList(u8) = .empty;
        defer command.deinit(self.allocator);
        const writer = command.writer(self.allocator);
        try writer.print("{s} {s} ", .{ verb, set });
        try wire.writeQuoted(writer, destination);

        var result = try self.runCommand(command.items, null);
        defer result.deinit();
        try self.ensureOk(&result);
        return parseCopyData(self.allocator, &result);
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

const AuthenticateStart = struct {
    allocator: std.mem.Allocator,
    continuation: []u8,
    result: CommandResult,

    fn deinit(self: *AuthenticateStart) void {
        self.allocator.free(self.continuation);
        self.result.deinit();
        self.* = undefined;
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

fn parseCopyData(allocator: std.mem.Allocator, result: *const CommandResult) !imap.CopyData {
    var data = imap.CopyData{};
    if (result.tagged.code) |code| {
        if (std.ascii.eqlIgnoreCase(code, "COPYUID")) {
            if (result.tagged.code_arg) |arg| {
                var it = std.mem.tokenizeAny(u8, arg, " ");
                if (it.next()) |uid_validity| data.uid_validity = std.fmt.parseInt(u32, uid_validity, 10) catch null;
                if (it.next()) |src| data.source_uids = try parseUidCsvAlloc(allocator, src);
                if (it.next()) |dst| data.dest_uids = try parseUidCsvAlloc(allocator, dst);
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

fn parseSortData(allocator: std.mem.Allocator, result: *const CommandResult) ![]u32 {
    for (result.untagged.items) |line| {
        if (!std.mem.startsWith(u8, line, "* SORT")) continue;
        const suffix = std.mem.trimLeft(u8, line["* SORT".len..], " ");
        if (suffix.len == 0) return allocator.alloc(u32, 0);

        var values: std.ArrayList(u32) = .empty;
        errdefer values.deinit(allocator);
        var it = std.mem.tokenizeAny(u8, suffix, " ");
        while (it.next()) |token| {
            try values.append(allocator, try std.fmt.parseInt(u32, token, 10));
        }
        return values.toOwnedSlice(allocator);
    }
    return error.InvalidSortResponse;
}

fn parseUidCsvAlloc(allocator: std.mem.Allocator, text: []const u8) ![]const imap.UID {
    if (text.len == 0) return allocator.alloc(imap.UID, 0);
    var count: usize = 1;
    for (text) |byte| {
        if (byte == ',') count += 1;
    }
    const values = try allocator.alloc(imap.UID, count);
    var it = std.mem.splitScalar(u8, text, ',');
    var index: usize = 0;
    while (it.next()) |part| : (index += 1) {
        values[index] = try std.fmt.parseInt(imap.UID, part, 10);
    }
    return values;
}
