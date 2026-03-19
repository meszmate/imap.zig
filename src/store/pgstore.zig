const std = @import("std");

pub const Options = struct {
    psql_path: []const u8 = "psql",
    database_url: ?[]const u8 = null,
    host: ?[]const u8 = null,
    port: ?u16 = null,
    username: ?[]const u8 = null,
    database: ?[]const u8 = null,
};

pub const ExecFn = *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, options: Options, sql: []const u8) anyerror![]u8;

pub const PgStore = struct {
    allocator: std.mem.Allocator,
    options: Options,
    exec_ctx: *anyopaque,
    exec_fn: ExecFn,

    pub fn init(allocator: std.mem.Allocator, options: Options) PgStore {
        return .{
            .allocator = allocator,
            .options = options,
            .exec_ctx = undefined,
            .exec_fn = execViaPsql,
        };
    }

    pub fn initWithExecutor(allocator: std.mem.Allocator, options: Options, exec_ctx: *anyopaque, exec_fn: ExecFn) PgStore {
        return .{
            .allocator = allocator,
            .options = options,
            .exec_ctx = exec_ctx,
            .exec_fn = exec_fn,
        };
    }

    pub fn deinit(_: *PgStore) void {}

    pub fn schemaSql() []const u8 {
        return
            \\CREATE TABLE IF NOT EXISTS imap_users (
            \\    username TEXT PRIMARY KEY,
            \\    password TEXT NOT NULL
            \\);
            \\
            \\CREATE TABLE IF NOT EXISTS imap_mailboxes (
            \\    username TEXT NOT NULL,
            \\    name TEXT NOT NULL,
            \\    subscribed BOOLEAN NOT NULL DEFAULT FALSE,
            \\    uid_validity INTEGER NOT NULL DEFAULT 1,
            \\    uid_next INTEGER NOT NULL DEFAULT 1,
            \\    PRIMARY KEY (username, name),
            \\    FOREIGN KEY (username) REFERENCES imap_users(username) ON DELETE CASCADE
            \\);
            \\
            \\CREATE TABLE IF NOT EXISTS imap_messages (
            \\    id BIGSERIAL PRIMARY KEY,
            \\    username TEXT NOT NULL,
            \\    mailbox TEXT NOT NULL,
            \\    uid INTEGER NOT NULL,
            \\    body TEXT NOT NULL,
            \\    flags TEXT NOT NULL DEFAULT '',
            \\    internal_date BIGINT NOT NULL DEFAULT 0,
            \\    size BIGINT NOT NULL DEFAULT 0,
            \\    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            \\    FOREIGN KEY (username, mailbox) REFERENCES imap_mailboxes(username, name) ON DELETE CASCADE
            \\);
            \\
            \\CREATE INDEX IF NOT EXISTS idx_messages_mailbox ON imap_messages(username, mailbox, uid);
        ;
    }

    pub fn ensureSchema(self: *PgStore) !void {
        const out = try self.execSqlAlloc(schemaSql());
        self.allocator.free(out);
    }

    pub fn addUser(self: *PgStore, username: []const u8, password: []const u8) !void {
        const esc_user = try sqlEscapeAlloc(self.allocator, username);
        defer self.allocator.free(esc_user);
        const esc_password = try sqlEscapeAlloc(self.allocator, password);
        defer self.allocator.free(esc_password);
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "INSERT INTO imap_users (username, password) VALUES ('{s}', '{s}') ON CONFLICT (username) DO UPDATE SET password = EXCLUDED.password;",
            .{ esc_user, esc_password },
        );
        defer self.allocator.free(sql);
        const out = try self.execSqlAlloc(sql);
        self.allocator.free(out);
    }

    pub fn authenticate(self: *PgStore, username: []const u8, password: []const u8) !PgUser {
        const esc_user = try sqlEscapeAlloc(self.allocator, username);
        defer self.allocator.free(esc_user);
        const esc_password = try sqlEscapeAlloc(self.allocator, password);
        defer self.allocator.free(esc_password);
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "SELECT username FROM imap_users WHERE username = '{s}' AND password = '{s}' LIMIT 1;",
            .{ esc_user, esc_password },
        );
        defer self.allocator.free(sql);
        const out = try self.execSqlAlloc(sql);
        defer self.allocator.free(out);
        if (std.mem.trim(u8, out, " \r\n\t").len == 0) return error.InvalidCredentials;

        return .{
            .allocator = self.allocator,
            .store = self,
            .username = try self.allocator.dupe(u8, username),
        };
    }

    pub fn createMailbox(self: *PgStore, username: []const u8, mailbox: []const u8) !void {
        const esc_user = try sqlEscapeAlloc(self.allocator, username);
        defer self.allocator.free(esc_user);
        const esc_mailbox = try sqlEscapeAlloc(self.allocator, mailbox);
        defer self.allocator.free(esc_mailbox);
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "INSERT INTO imap_mailboxes (username, name, subscribed) VALUES ('{s}', '{s}', FALSE) ON CONFLICT (username, name) DO NOTHING;",
            .{ esc_user, esc_mailbox },
        );
        defer self.allocator.free(sql);
        const out = try self.execSqlAlloc(sql);
        self.allocator.free(out);
    }

    pub fn deleteMailbox(self: *PgStore, username: []const u8, mailbox: []const u8) !void {
        if (std.ascii.eqlIgnoreCase(mailbox, "INBOX")) return error.CannotDeleteInbox;
        const esc_user = try sqlEscapeAlloc(self.allocator, username);
        defer self.allocator.free(esc_user);
        const esc_mailbox = try sqlEscapeAlloc(self.allocator, mailbox);
        defer self.allocator.free(esc_mailbox);
        const sql = try std.fmt.allocPrint(self.allocator, "DELETE FROM imap_mailboxes WHERE username = '{s}' AND name = '{s}';", .{ esc_user, esc_mailbox });
        defer self.allocator.free(sql);
        const out = try self.execSqlAlloc(sql);
        self.allocator.free(out);
    }

    pub fn renameMailbox(self: *PgStore, username: []const u8, old_name: []const u8, new_name: []const u8) !void {
        const esc_user = try sqlEscapeAlloc(self.allocator, username);
        defer self.allocator.free(esc_user);
        const esc_old = try sqlEscapeAlloc(self.allocator, old_name);
        defer self.allocator.free(esc_old);
        const esc_new = try sqlEscapeAlloc(self.allocator, new_name);
        defer self.allocator.free(esc_new);
        const sql = try std.fmt.allocPrint(self.allocator, "UPDATE imap_mailboxes SET name = '{s}' WHERE username = '{s}' AND name = '{s}'; " ++
            "UPDATE imap_messages SET mailbox = '{s}' WHERE username = '{s}' AND mailbox = '{s}';", .{ esc_new, esc_user, esc_old, esc_new, esc_user, esc_old });
        defer self.allocator.free(sql);
        const out = try self.execSqlAlloc(sql);
        self.allocator.free(out);
    }

    pub fn subscribeMailbox(self: *PgStore, username: []const u8, mailbox: []const u8) !void {
        const esc_user = try sqlEscapeAlloc(self.allocator, username);
        defer self.allocator.free(esc_user);
        const esc_mailbox = try sqlEscapeAlloc(self.allocator, mailbox);
        defer self.allocator.free(esc_mailbox);
        const sql = try std.fmt.allocPrint(self.allocator, "UPDATE imap_mailboxes SET subscribed = TRUE WHERE username = '{s}' AND name = '{s}';", .{ esc_user, esc_mailbox });
        defer self.allocator.free(sql);
        const out = try self.execSqlAlloc(sql);
        self.allocator.free(out);
    }

    pub fn unsubscribeMailbox(self: *PgStore, username: []const u8, mailbox: []const u8) !void {
        const esc_user = try sqlEscapeAlloc(self.allocator, username);
        defer self.allocator.free(esc_user);
        const esc_mailbox = try sqlEscapeAlloc(self.allocator, mailbox);
        defer self.allocator.free(esc_mailbox);
        const sql = try std.fmt.allocPrint(self.allocator, "UPDATE imap_mailboxes SET subscribed = FALSE WHERE username = '{s}' AND name = '{s}';", .{ esc_user, esc_mailbox });
        defer self.allocator.free(sql);
        const out = try self.execSqlAlloc(sql);
        self.allocator.free(out);
    }

    pub fn getMailboxStatus(self: *PgStore, username: []const u8, mailbox: []const u8) !MailboxStatus {
        const esc_user = try sqlEscapeAlloc(self.allocator, username);
        defer self.allocator.free(esc_user);
        const esc_mailbox = try sqlEscapeAlloc(self.allocator, mailbox);
        defer self.allocator.free(esc_mailbox);
        const sql = try std.fmt.allocPrint(self.allocator, "SELECT uid_validity, uid_next, " ++
            "(SELECT COUNT(*) FROM imap_messages WHERE username = '{s}' AND mailbox = '{s}'), " ++
            "(SELECT COUNT(*) FROM imap_messages WHERE username = '{s}' AND mailbox = '{s}' AND flags NOT LIKE '%\\Seen%') " ++
            "FROM imap_mailboxes WHERE username = '{s}' AND name = '{s}';", .{ esc_user, esc_mailbox, esc_user, esc_mailbox, esc_user, esc_mailbox });
        defer self.allocator.free(sql);
        const out = try self.execSqlAlloc(sql);
        defer self.allocator.free(out);
        return parseMailboxStatus(out);
    }

    fn execSqlAlloc(self: *PgStore, sql: []const u8) ![]u8 {
        return self.exec_fn(self.exec_ctx, self.allocator, self.options, sql);
    }
};

pub const PgUser = struct {
    allocator: std.mem.Allocator,
    store: *PgStore,
    username: []u8,

    pub fn deinit(self: *PgUser) void {
        self.allocator.free(self.username);
        self.* = undefined;
    }

    pub fn listMailboxesAlloc(self: *PgUser) ![][]u8 {
        const esc_user = try sqlEscapeAlloc(self.allocator, self.username);
        defer self.allocator.free(esc_user);
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "SELECT name FROM imap_mailboxes WHERE username = '{s}' ORDER BY name;",
            .{esc_user},
        );
        defer self.allocator.free(sql);
        const out = try self.store.execSqlAlloc(sql);
        defer self.allocator.free(out);
        return splitLinesAlloc(self.allocator, out);
    }

    pub fn deleteMailbox(self: *PgUser, mailbox: []const u8) !void {
        return self.store.deleteMailbox(self.username, mailbox);
    }

    pub fn createMailbox(self: *PgUser, mailbox: []const u8) !void {
        return self.store.createMailbox(self.username, mailbox);
    }

    pub fn renameMailbox(self: *PgUser, old_name: []const u8, new_name: []const u8) !void {
        return self.store.renameMailbox(self.username, old_name, new_name);
    }

    pub fn subscribeMailbox(self: *PgUser, mailbox: []const u8) !void {
        return self.store.subscribeMailbox(self.username, mailbox);
    }

    pub fn unsubscribeMailbox(self: *PgUser, mailbox: []const u8) !void {
        return self.store.unsubscribeMailbox(self.username, mailbox);
    }

    pub fn appendMessage(self: *PgUser, mailbox: []const u8, message: []const u8) !void {
        const esc_user = try sqlEscapeAlloc(self.allocator, self.username);
        defer self.allocator.free(esc_user);
        const esc_mailbox = try sqlEscapeAlloc(self.allocator, mailbox);
        defer self.allocator.free(esc_mailbox);
        // Get and increment uid_next
        const uid_sql = try std.fmt.allocPrint(self.allocator, "UPDATE imap_mailboxes SET uid_next = uid_next + 1 WHERE username = '{s}' AND name = '{s}' RETURNING uid_next - 1;", .{ esc_user, esc_mailbox });
        defer self.allocator.free(uid_sql);
        const uid_out = try self.store.execSqlAlloc(uid_sql);
        defer self.allocator.free(uid_out);
        const uid = std.fmt.parseInt(u32, std.mem.trim(u8, uid_out, " \r\n\t"), 10) catch 1;
        const esc_message = try sqlEscapeAlloc(self.allocator, message);
        defer self.allocator.free(esc_message);
        const sql = try std.fmt.allocPrint(self.allocator, "INSERT INTO imap_messages (username, mailbox, uid, body, size) VALUES ('{s}', '{s}', {d}, '{s}', {d});", .{ esc_user, esc_mailbox, uid, esc_message, message.len });
        defer self.allocator.free(sql);
        const out = try self.store.execSqlAlloc(sql);
        self.allocator.free(out);
    }

    pub fn getMessageUids(self: *PgUser, mailbox: []const u8) ![]u32 {
        const esc_user = try sqlEscapeAlloc(self.allocator, self.username);
        defer self.allocator.free(esc_user);
        const esc_mailbox = try sqlEscapeAlloc(self.allocator, mailbox);
        defer self.allocator.free(esc_mailbox);
        const sql = try std.fmt.allocPrint(self.allocator, "SELECT uid FROM imap_messages WHERE username = '{s}' AND mailbox = '{s}' ORDER BY uid;", .{ esc_user, esc_mailbox });
        defer self.allocator.free(sql);
        const out = try self.store.execSqlAlloc(sql);
        defer self.allocator.free(out);
        return parseUidList(self.allocator, out);
    }

    pub fn setFlags(self: *PgUser, mailbox: []const u8, uid: u32, flags_str: []const u8) !void {
        const esc_user = try sqlEscapeAlloc(self.allocator, self.username);
        defer self.allocator.free(esc_user);
        const esc_mailbox = try sqlEscapeAlloc(self.allocator, mailbox);
        defer self.allocator.free(esc_mailbox);
        const esc_flags = try sqlEscapeAlloc(self.allocator, flags_str);
        defer self.allocator.free(esc_flags);
        const sql = try std.fmt.allocPrint(self.allocator, "UPDATE imap_messages SET flags = '{s}' WHERE username = '{s}' AND mailbox = '{s}' AND uid = {d};", .{ esc_flags, esc_user, esc_mailbox, uid });
        defer self.allocator.free(sql);
        const out = try self.store.execSqlAlloc(sql);
        self.allocator.free(out);
    }

    pub fn expungeMessages(self: *PgUser, mailbox: []const u8) ![]u32 {
        const esc_user = try sqlEscapeAlloc(self.allocator, self.username);
        defer self.allocator.free(esc_user);
        const esc_mailbox = try sqlEscapeAlloc(self.allocator, mailbox);
        defer self.allocator.free(esc_mailbox);
        // Get UIDs of deleted messages first
        const sql_select = try std.fmt.allocPrint(self.allocator, "SELECT uid FROM imap_messages WHERE username = '{s}' AND mailbox = '{s}' AND flags LIKE '%\\Deleted%' ORDER BY uid;", .{ esc_user, esc_mailbox });
        defer self.allocator.free(sql_select);
        const uid_out = try self.store.execSqlAlloc(sql_select);
        defer self.allocator.free(uid_out);
        const uids = try parseUidList(self.allocator, uid_out);
        // Delete them
        const sql_delete = try std.fmt.allocPrint(self.allocator, "DELETE FROM imap_messages WHERE username = '{s}' AND mailbox = '{s}' AND flags LIKE '%\\Deleted%';", .{ esc_user, esc_mailbox });
        defer self.allocator.free(sql_delete);
        const del_out = try self.store.execSqlAlloc(sql_delete);
        self.allocator.free(del_out);
        return uids;
    }

    pub fn copyMessages(self: *PgUser, src_mailbox: []const u8, uids: []const u32, dest_mailbox: []const u8) ![]u32 {
        var dest_uids: std.ArrayList(u32) = .empty;
        errdefer dest_uids.deinit(self.allocator);
        for (uids) |uid| {
            const esc_user = try sqlEscapeAlloc(self.allocator, self.username);
            defer self.allocator.free(esc_user);
            const esc_src = try sqlEscapeAlloc(self.allocator, src_mailbox);
            defer self.allocator.free(esc_src);
            const esc_dest = try sqlEscapeAlloc(self.allocator, dest_mailbox);
            defer self.allocator.free(esc_dest);
            // Get next UID for destination
            const uid_sql = try std.fmt.allocPrint(self.allocator, "UPDATE imap_mailboxes SET uid_next = uid_next + 1 WHERE username = '{s}' AND name = '{s}' RETURNING uid_next - 1;", .{ esc_user, esc_dest });
            defer self.allocator.free(uid_sql);
            const uid_out = try self.store.execSqlAlloc(uid_sql);
            defer self.allocator.free(uid_out);
            const new_uid = std.fmt.parseInt(u32, std.mem.trim(u8, uid_out, " \r\n\t"), 10) catch continue;
            try dest_uids.append(self.allocator, new_uid);
            // Copy the message
            const copy_sql = try std.fmt.allocPrint(self.allocator, "INSERT INTO imap_messages (username, mailbox, uid, body, flags, internal_date, size) " ++
                "SELECT username, '{s}', {d}, body, flags, internal_date, size FROM imap_messages " ++
                "WHERE username = '{s}' AND mailbox = '{s}' AND uid = {d};", .{ esc_dest, new_uid, esc_user, esc_src, uid });
            defer self.allocator.free(copy_sql);
            const copy_out = try self.store.execSqlAlloc(copy_sql);
            self.allocator.free(copy_out);
        }
        return dest_uids.toOwnedSlice(self.allocator);
    }
};

pub const MailboxStatus = struct {
    uid_validity: u32 = 1,
    uid_next: u32 = 1,
    num_messages: u32 = 0,
    num_unseen: u32 = 0,
};

fn parseMailboxStatus(output: []const u8) !MailboxStatus {
    const trimmed = std.mem.trim(u8, output, " \r\n\t");
    if (trimmed.len == 0) return error.NoSuchMailbox;
    var it = std.mem.splitScalar(u8, trimmed, '|');
    var status = MailboxStatus{};
    if (it.next()) |v| status.uid_validity = std.fmt.parseInt(u32, std.mem.trim(u8, v, " "), 10) catch 1;
    if (it.next()) |v| status.uid_next = std.fmt.parseInt(u32, std.mem.trim(u8, v, " "), 10) catch 1;
    if (it.next()) |v| status.num_messages = std.fmt.parseInt(u32, std.mem.trim(u8, v, " "), 10) catch 0;
    if (it.next()) |v| status.num_unseen = std.fmt.parseInt(u32, std.mem.trim(u8, v, " "), 10) catch 0;
    return status;
}

fn parseUidList(allocator: std.mem.Allocator, text: []const u8) ![]u32 {
    var out: std.ArrayList(u32) = .empty;
    errdefer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;
        const uid = std.fmt.parseInt(u32, trimmed, 10) catch continue;
        try out.append(allocator, uid);
    }
    return out.toOwnedSlice(allocator);
}

fn execViaPsql(_: *anyopaque, allocator: std.mem.Allocator, options: Options, sql: []const u8) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    var port_text: ?[]u8 = null;
    defer if (port_text) |value| allocator.free(value);

    try argv.append(allocator, options.psql_path);
    try argv.append(allocator, "-X");
    try argv.append(allocator, "-A");
    try argv.append(allocator, "-t");
    try argv.append(allocator, "-v");
    try argv.append(allocator, "ON_ERROR_STOP=1");
    if (options.host) |host| {
        try argv.append(allocator, "-h");
        try argv.append(allocator, host);
    }
    if (options.port) |port| {
        const rendered = try std.fmt.allocPrint(allocator, "{d}", .{port});
        port_text = rendered;
        try argv.append(allocator, "-p");
        try argv.append(allocator, rendered);
    }
    if (options.username) |username| {
        try argv.append(allocator, "-U");
        try argv.append(allocator, username);
    }
    if (options.database) |database| {
        try argv.append(allocator, "-d");
        try argv.append(allocator, database);
    } else if (options.database_url) |url| {
        try argv.append(allocator, url);
    }
    try argv.append(allocator, "-c");
    try argv.append(allocator, sql);

    const run = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .max_output_bytes = 1024 * 1024,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.PsqlNotAvailable,
        else => return err,
    };
    defer allocator.free(run.stdout);
    defer allocator.free(run.stderr);

    switch (run.term) {
        .Exited => |code| if (code == 0) return allocator.dupe(u8, run.stdout),
        else => {},
    }
    return error.PsqlCommandFailed;
}

fn splitLinesAlloc(allocator: std.mem.Allocator, text: []const u8) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit(allocator);
    }
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, "\r");
        if (trimmed.len == 0) continue;
        try out.append(allocator, try allocator.dupe(u8, trimmed));
    }
    return out.toOwnedSlice(allocator);
}

fn sqlEscapeAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (value) |byte| {
        if (byte == '\'') {
            try out.append(allocator, '\'');
            try out.append(allocator, '\'');
        } else {
            try out.append(allocator, byte);
        }
    }
    return out.toOwnedSlice(allocator);
}
