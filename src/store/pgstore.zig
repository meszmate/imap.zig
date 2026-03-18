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
            \\    PRIMARY KEY (username, name),
            \\    FOREIGN KEY (username) REFERENCES imap_users(username) ON DELETE CASCADE
            \\);
            \\
            \\CREATE TABLE IF NOT EXISTS imap_messages (
            \\    id BIGSERIAL PRIMARY KEY,
            \\    username TEXT NOT NULL,
            \\    mailbox TEXT NOT NULL,
            \\    body TEXT NOT NULL,
            \\    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            \\    FOREIGN KEY (username, mailbox) REFERENCES imap_mailboxes(username, name) ON DELETE CASCADE
            \\);
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

    pub fn appendMessage(self: *PgUser, mailbox: []const u8, message: []const u8) !void {
        const esc_user = try sqlEscapeAlloc(self.allocator, self.username);
        defer self.allocator.free(esc_user);
        const esc_mailbox = try sqlEscapeAlloc(self.allocator, mailbox);
        defer self.allocator.free(esc_mailbox);
        const esc_message = try sqlEscapeAlloc(self.allocator, message);
        defer self.allocator.free(esc_message);
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "INSERT INTO imap_messages (username, mailbox, body) VALUES ('{s}', '{s}', '{s}');",
            .{ esc_user, esc_mailbox, esc_message },
        );
        defer self.allocator.free(sql);
        const out = try self.store.execSqlAlloc(sql);
        self.allocator.free(out);
    }
};

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
