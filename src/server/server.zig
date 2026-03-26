const std = @import("std");
const imap = @import("../root.zig");
const memstore = @import("../store/memstore.zig");
const wire = @import("../wire/root.zig");
const auth = @import("../auth/root.zig");
const Options = @import("options.zig").Options;

pub const Server = struct {
    allocator: std.mem.Allocator,
    store: *memstore.MemStore,
    options: Options,

    pub fn init(allocator: std.mem.Allocator, store: *memstore.MemStore) Server {
        return .{
            .allocator = allocator,
            .store = store,
            .options = .{},
        };
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, store: *memstore.MemStore, options: Options) Server {
        return .{
            .allocator = allocator,
            .store = store,
            .options = options,
        };
    }

    fn currentCapabilities(self: *Server, session: *const SessionState) []const u8 {
        if (self.options.enable_starttls and !session.is_tls) {
            if (!self.options.allow_insecure_auth) {
                return Options.logindisabledCapabilities();
            }
            return Options.starttlsCapabilities();
        }
        return Options.defaultCapabilities();
    }

    /// Serve an IMAP session over the given transport.
    /// If `stream` is provided, STARTTLS upgrade is supported via the configured callback.
    pub fn serveConnection(self: *Server, initial_transport: wire.Transport, stream: ?std.net.Stream, is_tls: bool) !void {
        var current_transport = initial_transport;
        var reader = wire.LineReader.init(self.allocator, current_transport);
        var session = SessionState{
            .underlying_stream = stream,
            .is_tls = is_tls,
        };

        try current_transport.print("* OK [CAPABILITY {s}] {s}\r\n", .{ self.currentCapabilities(&session), self.options.greeting_text });

        while (session.state != .logout) {
            const line = reader.readLineAlloc() catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            defer self.allocator.free(line);

            if (line.len == 0) continue;

            var tokens = try tokenizeLine(self.allocator, line);
            defer tokens.deinit(self.allocator);
            if (tokens.items.len < 2) {
                try current_transport.writeAll("* BAD malformed command\r\n");
                continue;
            }

            const tag = tokens.items[0].value;
            var command_name = tokens.items[1].value;
            var args = tokens.items[2..];
            const uid_mode = std.ascii.eqlIgnoreCase(command_name, "UID");
            if (uid_mode) {
                if (args.len == 0) {
                    try writeTagged(current_transport, tag, .bad, null, "missing UID subcommand");
                    continue;
                }
                command_name = args[0].value;
                args = args[1..];
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.capability)) {
                try current_transport.print("* CAPABILITY {s}\r\n", .{self.currentCapabilities(&session)});
                try writeTagged(current_transport, tag, .ok, null, "CAPABILITY completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.noop)) {
                if (session.selected) |mailbox| {
                    try current_transport.print("* {d} EXISTS\r\n", .{mailbox.messages.items.len});
                }
                try writeTagged(current_transport, tag, .ok, null, "NOOP completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.logout)) {
                try current_transport.writeAll("* BYE logging out\r\n");
                session.state = .logout;
                try writeTagged(current_transport, tag, .ok, null, "LOGOUT completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.namespace)) {
                try current_transport.writeAll("* NAMESPACE ((\"\" \"/\")) NIL NIL\r\n");
                try writeTagged(current_transport, tag, .ok, null, "NAMESPACE completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.id)) {
                try current_transport.writeAll("* ID NIL\r\n");
                try writeTagged(current_transport, tag, .ok, null, "ID completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.enable)) {
                try writeTagged(current_transport, tag, .ok, null, "ENABLE completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.authenticate)) {
                if (self.options.enable_starttls and !self.options.allow_insecure_auth and !session.is_tls) {
                    try writeTagged(current_transport, tag, .no, null, "AUTHENTICATE requires TLS — use STARTTLS first");
                    continue;
                }
                if (args.len < 1) {
                    try writeTagged(current_transport, tag, .bad, null, "AUTHENTICATE requires mechanism");
                    continue;
                }
                const mechanism = args[0].value;
                const initial = if (args.len >= 2) args[1].value else null;
                if (std.ascii.eqlIgnoreCase(mechanism, "PLAIN")) {
                    const response = try readAuthResponseAlloc(self.allocator, &reader, current_transport, initial, null);
                    defer self.allocator.free(response);
                    const creds = auth.plain.decodeResponseAlloc(self.allocator, std.mem.trim(u8, response, " ")) catch {
                        try writeTagged(current_transport, tag, .bad, null, "invalid PLAIN response");
                        continue;
                    };
                    defer {
                        self.allocator.free(creds.authzid);
                        self.allocator.free(creds.username);
                        self.allocator.free(creds.password);
                    }
                    const user = self.store.authenticate(creds.username, creds.password) catch {
                        try writeTagged(current_transport, tag, .no, null, "authentication failed");
                        continue;
                    };
                    session.user = user;
                    session.state = .authenticated;
                    try writeTagged(current_transport, tag, .ok, null, "AUTHENTICATE completed");
                    continue;
                }
                if (std.ascii.eqlIgnoreCase(mechanism, "EXTERNAL")) {
                    const response = try readAuthResponseAlloc(self.allocator, &reader, current_transport, initial, null);
                    defer self.allocator.free(response);
                    const authzid = auth.external.decodeAlloc(self.allocator, std.mem.trim(u8, response, " ")) catch {
                        try writeTagged(current_transport, tag, .bad, null, "invalid EXTERNAL response");
                        continue;
                    };
                    defer self.allocator.free(authzid);
                    const user = self.store.authenticateExternal(authzid) catch {
                        try writeTagged(current_transport, tag, .no, null, "authentication failed");
                        continue;
                    };
                    session.user = user;
                    session.state = .authenticated;
                    try writeTagged(current_transport, tag, .ok, null, "AUTHENTICATE completed");
                    continue;
                }
                if (std.ascii.eqlIgnoreCase(mechanism, "LOGIN")) {
                    try current_transport.print("+ {s}\r\n", .{auth.login.usernamePrompt()});
                    const username_b64 = try reader.readLineAlloc();
                    defer self.allocator.free(username_b64);
                    const username = auth.login.decodeAlloc(self.allocator, std.mem.trim(u8, username_b64, " ")) catch {
                        try writeTagged(current_transport, tag, .bad, null, "invalid LOGIN username");
                        continue;
                    };
                    defer self.allocator.free(username);
                    try current_transport.print("+ {s}\r\n", .{auth.login.passwordPrompt()});
                    const password_b64 = try reader.readLineAlloc();
                    defer self.allocator.free(password_b64);
                    const password = auth.login.decodeAlloc(self.allocator, std.mem.trim(u8, password_b64, " ")) catch {
                        try writeTagged(current_transport, tag, .bad, null, "invalid LOGIN password");
                        continue;
                    };
                    defer self.allocator.free(password);
                    const user = self.store.authenticate(username, password) catch {
                        try writeTagged(current_transport, tag, .no, null, "authentication failed");
                        continue;
                    };
                    session.user = user;
                    session.state = .authenticated;
                    try writeTagged(current_transport, tag, .ok, null, "AUTHENTICATE completed");
                    continue;
                }
                if (std.ascii.eqlIgnoreCase(mechanism, "ANONYMOUS")) {
                    const response = try readAuthResponseAlloc(self.allocator, &reader, current_transport, initial, null);
                    defer self.allocator.free(response);
                    const trace = auth.anonymous.decodeAlloc(self.allocator, std.mem.trim(u8, response, " ")) catch {
                        try writeTagged(current_transport, tag, .bad, null, "invalid ANONYMOUS response");
                        continue;
                    };
                    defer self.allocator.free(trace);
                    const user = self.store.authenticateAnonymous() catch {
                        try writeTagged(current_transport, tag, .no, null, "authentication failed");
                        continue;
                    };
                    session.user = user;
                    session.state = .authenticated;
                    try writeTagged(current_transport, tag, .ok, null, "AUTHENTICATE completed");
                    continue;
                }
                if (std.ascii.eqlIgnoreCase(mechanism, "CRAM-MD5")) {
                    const challenge = try fixedCramMd5ChallengeAlloc(self.allocator);
                    defer self.allocator.free(challenge);
                    const response = try readAuthResponseAlloc(self.allocator, &reader, current_transport, initial, challenge);
                    defer self.allocator.free(response);
                    const parsed = auth.crammd5.verifyResponseAlloc(self.allocator, std.mem.trim(u8, response, " "), challenge) catch {
                        try writeTagged(current_transport, tag, .bad, null, "invalid CRAM-MD5 response");
                        continue;
                    };
                    defer {
                        self.allocator.free(parsed.username);
                        self.allocator.free(parsed.digest);
                    }
                    const user = self.store.users.get(parsed.username) orelse {
                        try writeTagged(current_transport, tag, .no, null, "authentication failed");
                        continue;
                    };
                    const expected = auth.crammd5.expectedDigestAlloc(self.allocator, user.password, challenge) catch {
                        try writeTagged(current_transport, tag, .no, null, "authentication failed");
                        continue;
                    };
                    defer self.allocator.free(expected);
                    if (!std.ascii.eqlIgnoreCase(expected, parsed.digest)) {
                        try writeTagged(current_transport, tag, .no, null, "authentication failed");
                        continue;
                    }
                    session.user = user;
                    session.state = .authenticated;
                    try writeTagged(current_transport, tag, .ok, null, "AUTHENTICATE completed");
                    continue;
                }
                if (std.ascii.eqlIgnoreCase(mechanism, "XOAUTH2")) {
                    const response = try readAuthResponseAlloc(self.allocator, &reader, current_transport, initial, null);
                    defer self.allocator.free(response);
                    const creds = auth.xoauth2.decodeAlloc(self.allocator, std.mem.trim(u8, response, " ")) catch {
                        try writeTagged(current_transport, tag, .bad, null, "invalid XOAUTH2 response");
                        continue;
                    };
                    defer {
                        self.allocator.free(creds.user);
                        self.allocator.free(creds.access_token);
                    }
                    const user = self.store.authenticateToken(creds.user, creds.access_token) catch {
                        try writeTagged(current_transport, tag, .no, null, "authentication failed");
                        continue;
                    };
                    session.user = user;
                    session.state = .authenticated;
                    try writeTagged(current_transport, tag, .ok, null, "AUTHENTICATE completed");
                    continue;
                }
                if (std.ascii.eqlIgnoreCase(mechanism, "OAUTHBEARER")) {
                    const response = try readAuthResponseAlloc(self.allocator, &reader, current_transport, initial, null);
                    defer self.allocator.free(response);
                    const creds = auth.oauthbearer.decodeAlloc(self.allocator, std.mem.trim(u8, response, " ")) catch {
                        try writeTagged(current_transport, tag, .bad, null, "invalid OAUTHBEARER response");
                        continue;
                    };
                    defer {
                        self.allocator.free(creds.authzid);
                        self.allocator.free(creds.access_token);
                        self.allocator.free(creds.host);
                    }
                    const user = self.store.authenticateToken(creds.authzid, creds.access_token) catch {
                        try writeTagged(current_transport, tag, .no, null, "authentication failed");
                        continue;
                    };
                    session.user = user;
                    session.state = .authenticated;
                    try writeTagged(current_transport, tag, .ok, null, "AUTHENTICATE completed");
                    continue;
                }
                try writeTagged(current_transport, tag, .bad, null, "unsupported AUTHENTICATE mechanism");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.login)) {
                if (self.options.enable_starttls and !self.options.allow_insecure_auth and !session.is_tls) {
                    try writeTagged(current_transport, tag, .no, null, "LOGIN requires TLS — use STARTTLS first");
                    continue;
                }
                if (args.len < 2) {
                    try writeTagged(current_transport, tag, .bad, null, "LOGIN requires username and password");
                    continue;
                }
                const user = self.store.authenticate(args[0].value, args[1].value) catch {
                    try writeTagged(current_transport, tag, .no, null, "invalid credentials");
                    continue;
                };
                session.user = user;
                session.state = .authenticated;
                try writeTagged(current_transport, tag, .ok, null, "LOGIN completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.list)) {
                if (session.user == null) {
                    try writeTagged(current_transport, tag, .bad, null, "not authenticated");
                    continue;
                }
                if (args.len < 2) {
                    try writeTagged(current_transport, tag, .bad, null, "LIST requires reference and pattern");
                    continue;
                }
                try self.handleList(current_transport, session.user.?, args[0].value, args[1].value);
                try writeTagged(current_transport, tag, .ok, null, "LIST completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.lsub)) {
                if (session.user == null) {
                    try writeTagged(current_transport, tag, .bad, null, "not authenticated");
                    continue;
                }
                if (args.len < 2) {
                    try writeTagged(current_transport, tag, .bad, null, "LSUB requires reference and pattern");
                    continue;
                }
                try self.handleLsub(current_transport, session.user.?, args[0].value, args[1].value);
                try writeTagged(current_transport, tag, .ok, null, "LSUB completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.create)) {
                if (session.user == null or args.len < 1) {
                    try writeTagged(current_transport, tag, .bad, null, "CREATE requires mailbox");
                    continue;
                }
                session.user.?.createMailbox(args[0].value, &self.store.next_uid_validity) catch {
                    try writeTagged(current_transport, tag, .no, null, "mailbox already exists");
                    continue;
                };
                try writeTagged(current_transport, tag, .ok, null, "CREATE completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.delete)) {
                if (session.user == null or args.len < 1) {
                    try writeTagged(current_transport, tag, .bad, null, "DELETE requires mailbox");
                    continue;
                }
                session.user.?.deleteMailbox(args[0].value) catch {
                    try writeTagged(current_transport, tag, .no, null, "cannot delete mailbox");
                    continue;
                };
                try writeTagged(current_transport, tag, .ok, null, "DELETE completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.rename)) {
                if (session.user == null or args.len < 2) {
                    try writeTagged(current_transport, tag, .bad, null, "RENAME requires source and destination");
                    continue;
                }
                session.user.?.renameMailbox(args[0].value, args[1].value) catch {
                    try writeTagged(current_transport, tag, .no, null, "rename failed");
                    continue;
                };
                try writeTagged(current_transport, tag, .ok, null, "RENAME completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.subscribe) or std.ascii.eqlIgnoreCase(command_name, imap.commands.unsubscribe)) {
                if (session.user == null or args.len < 1) {
                    try writeTagged(current_transport, tag, .bad, null, "mailbox required");
                    continue;
                }
                const mailbox = session.user.?.getMailbox(args[0].value) orelse {
                    try writeTagged(current_transport, tag, .no, null, "no such mailbox");
                    continue;
                };
                mailbox.subscribed = std.ascii.eqlIgnoreCase(command_name, imap.commands.subscribe);
                try writeTagged(current_transport, tag, .ok, null, "subscription updated");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.select) or std.ascii.eqlIgnoreCase(command_name, imap.commands.examine)) {
                if (session.user == null or args.len < 1) {
                    try writeTagged(current_transport, tag, .bad, null, "SELECT requires mailbox");
                    continue;
                }
                const mailbox = session.user.?.getMailbox(args[0].value) orelse {
                    try writeTagged(current_transport, tag, .no, null, "no such mailbox");
                    continue;
                };
                session.selected = mailbox;
                session.state = .selected;
                session.read_only = std.ascii.eqlIgnoreCase(command_name, imap.commands.examine);
                try self.writeSelectData(current_transport, mailbox, session.read_only);
                try writeTagged(
                    current_transport,
                    tag,
                    .ok,
                    if (session.read_only) "READ-ONLY" else "READ-WRITE",
                    if (session.read_only) "EXAMINE completed" else "SELECT completed",
                );
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.status)) {
                if (session.user == null or args.len < 2) {
                    try writeTagged(current_transport, tag, .bad, null, "STATUS requires mailbox and items");
                    continue;
                }
                const mailbox = session.user.?.getMailbox(args[0].value) orelse {
                    try writeTagged(current_transport, tag, .no, null, "no such mailbox");
                    continue;
                };
                try self.writeStatusData(current_transport, mailbox, args[1].value);
                try writeTagged(current_transport, tag, .ok, null, "STATUS completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.append)) {
                if (session.user == null or args.len < 2) {
                    try writeTagged(current_transport, tag, .bad, null, "APPEND requires mailbox and literal");
                    continue;
                }
                const mailbox = session.user.?.getMailbox(args[0].value) orelse {
                    try writeTagged(current_transport, tag, .no, null, "no such mailbox");
                    continue;
                };
                const literal_token = args[args.len - 1].value;
                const literal_len = parseLiteralMarker(literal_token) catch {
                    try writeTagged(current_transport, tag, .bad, null, "APPEND requires literal");
                    continue;
                };
                var append_flags = std.ArrayList([]const u8).empty;
                defer freeOwnedStrings(self.allocator, &append_flags);
                if (args.len >= 3 and tokensHaveList(args[1])) {
                    try parseFlagList(self.allocator, args[1].value, &append_flags);
                }
                try current_transport.writeAll("+ Ready for literal data\r\n");
                const bytes = try reader.readExactAlloc(literal_len);
                defer self.allocator.free(bytes);
                try reader.readCrlf();
                const uid = try mailbox.appendMessage(bytes, append_flags.items, null);
                const code = try std.fmt.allocPrint(self.allocator, "APPENDUID {d} {d}", .{ mailbox.uid_validity, uid });
                defer self.allocator.free(code);
                try writeTagged(current_transport, tag, .ok, code, "APPEND completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.unselect)) {
                session.selected = null;
                if (session.user != null) session.state = .authenticated;
                session.read_only = false;
                try writeTagged(current_transport, tag, .ok, null, "UNSELECT completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.idle)) {
                if (session.user == null) {
                    try writeTagged(current_transport, tag, .bad, null, "not authenticated");
                    continue;
                }
                try current_transport.writeAll("+ idling\r\n");
                if (session.selected) |mailbox| {
                    try current_transport.print("* {d} EXISTS\r\n", .{mailbox.messages.items.len});
                }
                while (true) {
                    const idle_line = reader.readLineAlloc() catch |err| switch (err) {
                        error.EndOfStream => {
                            session.state = .logout;
                            return;
                        },
                        else => return err,
                    };
                    defer self.allocator.free(idle_line);
                    if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, idle_line, " "), "DONE")) break;
                }
                try writeTagged(current_transport, tag, .ok, null, "IDLE completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.sort)) {
                if (session.user == null or session.selected == null) {
                    try writeTagged(current_transport, tag, .bad, null, "SORT requires selected state");
                    continue;
                }
                const mailbox = session.selected.?;
                if (args.len < 2) {
                    try writeTagged(current_transport, tag, .bad, null, "SORT requires criteria and charset");
                    continue;
                }
                const criteria = try parseSortCriteria(self.allocator, args[0]);
                defer self.allocator.free(criteria);
                var search_criteria = try parseSearchCriteria(self.allocator, args[2..]);
                defer freeSearchCriteria(self.allocator, &search_criteria);
                const sorted = try sortMailbox(self.allocator, mailbox, uid_mode, criteria, search_criteria);
                defer self.allocator.free(sorted);

                const ids_buf = try joinU32sSpace(self.allocator, sorted);
                defer self.allocator.free(ids_buf);
                try current_transport.print("* SORT {s}\r\n", .{ids_buf});
                try writeTagged(current_transport, tag, .ok, null, "SORT completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.thread)) {
                if (session.user == null or session.selected == null) {
                    try writeTagged(current_transport, tag, .bad, null, "THREAD requires selected state");
                    continue;
                }
                const mailbox = session.selected.?;
                if (args.len < 2) {
                    try writeTagged(current_transport, tag, .bad, null, "THREAD requires algorithm and charset");
                    continue;
                }
                const algorithm = if (std.ascii.eqlIgnoreCase(args[0].value, "REFERENCES"))
                    imap.ThreadAlgorithm.references
                else
                    imap.ThreadAlgorithm.orderedsubject;
                var search_criteria = try parseSearchCriteria(self.allocator, args[2..]);
                defer freeSearchCriteria(self.allocator, &search_criteria);
                const thread_text = try threadMailbox(self.allocator, mailbox, uid_mode, algorithm, search_criteria);
                defer self.allocator.free(thread_text);
                try current_transport.print("* THREAD {s}\r\n", .{thread_text});
                try writeTagged(current_transport, tag, .ok, null, "THREAD completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.getacl)) {
                if (session.user == null) {
                    try writeTagged(current_transport, tag, .bad, null, "not authenticated");
                    continue;
                }
                if (args.len < 1) {
                    try writeTagged(current_transport, tag, .bad, null, "GETACL requires mailbox");
                    continue;
                }
                const mailbox = session.user.?.getMailbox(args[0].value) orelse {
                    try writeTagged(current_transport, tag, .no, null, "no such mailbox");
                    continue;
                };
                try self.writeAclData(current_transport, mailbox, session.user.?);
                try writeTagged(current_transport, tag, .ok, null, "GETACL completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.setacl)) {
                if (session.user == null) {
                    try writeTagged(current_transport, tag, .bad, null, "not authenticated");
                    continue;
                }
                if (args.len < 3) {
                    try writeTagged(current_transport, tag, .bad, null, "SETACL requires mailbox, identifier, rights");
                    continue;
                }
                const mailbox = session.user.?.getMailbox(args[0].value) orelse {
                    try writeTagged(current_transport, tag, .no, null, "no such mailbox");
                    continue;
                };
                try mailbox.setAcl(args[1].value, args[2].value);
                try writeTagged(current_transport, tag, .ok, null, "SETACL completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.deleteacl)) {
                if (session.user == null) {
                    try writeTagged(current_transport, tag, .bad, null, "not authenticated");
                    continue;
                }
                if (args.len < 2) {
                    try writeTagged(current_transport, tag, .bad, null, "DELETEACL requires mailbox and identifier");
                    continue;
                }
                const mailbox = session.user.?.getMailbox(args[0].value) orelse {
                    try writeTagged(current_transport, tag, .no, null, "no such mailbox");
                    continue;
                };
                _ = mailbox.deleteAcl(args[1].value);
                try writeTagged(current_transport, tag, .ok, null, "DELETEACL completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.listrights)) {
                if (session.user == null) {
                    try writeTagged(current_transport, tag, .bad, null, "not authenticated");
                    continue;
                }
                if (args.len < 2) {
                    try writeTagged(current_transport, tag, .bad, null, "LISTRIGHTS requires mailbox and identifier");
                    continue;
                }
                try current_transport.print("* LISTRIGHTS {s} {s} \"\" l r s w i p k x t e a\r\n", .{ args[0].value, args[1].value });
                try writeTagged(current_transport, tag, .ok, null, "LISTRIGHTS completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.myrights)) {
                if (session.user == null) {
                    try writeTagged(current_transport, tag, .bad, null, "not authenticated");
                    continue;
                }
                if (args.len < 1) {
                    try writeTagged(current_transport, tag, .bad, null, "MYRIGHTS requires mailbox");
                    continue;
                }
                const mailbox = session.user.?.getMailbox(args[0].value) orelse {
                    try writeTagged(current_transport, tag, .no, null, "no such mailbox");
                    continue;
                };
                try current_transport.print("* MYRIGHTS {s} {s}\r\n", .{ args[0].value, mailbox.getRights(session.user.?.username, session.user.?.username) });
                try writeTagged(current_transport, tag, .ok, null, "MYRIGHTS completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.getquota)) {
                if (session.user == null) {
                    try writeTagged(current_transport, tag, .bad, null, "not authenticated");
                    continue;
                }
                if (args.len < 1) {
                    try writeTagged(current_transport, tag, .bad, null, "GETQUOTA requires root");
                    continue;
                }
                try self.writeQuota(current_transport, session.user.?);
                try writeTagged(current_transport, tag, .ok, null, "GETQUOTA completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.setquota)) {
                if (session.user == null) {
                    try writeTagged(current_transport, tag, .bad, null, "not authenticated");
                    continue;
                }
                if (args.len >= 2) {
                    try applyQuotaResources(session.user.?, args[1]);
                }
                try writeTagged(current_transport, tag, .ok, null, "SETQUOTA completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.getquotaroot)) {
                if (session.user == null) {
                    try writeTagged(current_transport, tag, .bad, null, "not authenticated");
                    continue;
                }
                if (args.len < 1) {
                    try writeTagged(current_transport, tag, .bad, null, "GETQUOTAROOT requires mailbox");
                    continue;
                }
                try current_transport.print("* QUOTAROOT {s} \"{s}\"\r\n", .{ args[0].value, session.user.?.quota_root });
                try self.writeQuota(current_transport, session.user.?);
                try writeTagged(current_transport, tag, .ok, null, "GETQUOTAROOT completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.getmetadata)) {
                if (session.user == null) {
                    try writeTagged(current_transport, tag, .bad, null, "not authenticated");
                    continue;
                }
                if (args.len < 1) {
                    try writeTagged(current_transport, tag, .bad, null, "GETMETADATA requires mailbox");
                    continue;
                }
                const mailbox = session.user.?.getMailbox(args[0].value) orelse {
                    try writeTagged(current_transport, tag, .no, null, "no such mailbox");
                    continue;
                };
                try self.writeMetadata(current_transport, mailbox, if (args.len >= 2) args[1] else null);
                try writeTagged(current_transport, tag, .ok, null, "GETMETADATA completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.setmetadata)) {
                if (session.user == null) {
                    try writeTagged(current_transport, tag, .bad, null, "not authenticated");
                    continue;
                }
                if (args.len < 2) {
                    try writeTagged(current_transport, tag, .bad, null, "SETMETADATA requires mailbox and entries");
                    continue;
                }
                const mailbox = session.user.?.getMailbox(args[0].value) orelse {
                    try writeTagged(current_transport, tag, .no, null, "no such mailbox");
                    continue;
                };
                try applyMetadataUpdates(self.allocator, mailbox, args[1]);
                try writeTagged(current_transport, tag, .ok, null, "SETMETADATA completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.compress)) {
                if (session.user == null) {
                    try writeTagged(current_transport, tag, .bad, null, "not authenticated");
                    continue;
                }
                // Accept but don't actually compress (stub for negotiation)
                try writeTagged(current_transport, tag, .ok, null, "COMPRESS completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.starttls)) {
                if (session.is_tls) {
                    try writeTagged(current_transport, tag, .bad, null, "already using TLS");
                    continue;
                }
                if (session.user != null) {
                    try writeTagged(current_transport, tag, .bad, null, "already authenticated");
                    continue;
                }
                if (self.options.tls_upgrade_fn) |upgrade_fn| {
                    // Send OK before upgrading (per RFC 3501)
                    try writeTagged(current_transport, tag, .ok, null, "Begin TLS negotiation now");
                    // Perform TLS upgrade via callback
                    const ctx = self.options.tls_upgrade_ctx orelse return error.MissingTlsContext;
                    current_transport = try upgrade_fn(ctx, session.underlying_stream orelse return error.NoUnderlyingStream);
                    reader = wire.LineReader.init(self.allocator, current_transport);
                    session.is_tls = true;
                } else {
                    // No TLS upgrade function configured — stub response for testing
                    try writeTagged(current_transport, tag, .ok, null, "Begin TLS negotiation now");
                }
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.unauthenticate)) {
                session.user = null;
                session.selected = null;
                session.read_only = false;
                session.state = .not_authenticated;
                try writeTagged(current_transport, tag, .ok, null, "UNAUTHENTICATE completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.replace)) {
                if (session.user == null or session.selected == null) {
                    try writeTagged(current_transport, tag, .bad, null, "REPLACE requires selected state");
                    continue;
                }
                // REPLACE needs at least: set, mailbox, literal size
                if (args.len < 2) {
                    try writeTagged(current_transport, tag, .bad, null, "REPLACE requires set and mailbox");
                    continue;
                }
                // Parse literal from last argument
                const last_arg = args[args.len - 1].value;
                const literal_len = parseLiteralMarker(last_arg) catch {
                    try writeTagged(current_transport, tag, .bad, null, "REPLACE requires literal");
                    continue;
                };
                try current_transport.writeAll("+ Ready for literal data\r\n");
                const body = try reader.readExactAlloc(literal_len);
                defer self.allocator.free(body);
                try reader.readCrlf();

                const mailbox_name = args[1].value;
                const user = session.user.?;
                const dest_mailbox = user.getMailbox(mailbox_name) orelse {
                    try writeTagged(current_transport, tag, .no, "TRYCREATE", "mailbox does not exist");
                    continue;
                };
                const new_uid = try dest_mailbox.appendMessage(body, &.{}, null);
                const code = try std.fmt.allocPrint(self.allocator, "APPENDUID {d} {d}", .{ dest_mailbox.uid_validity, new_uid });
                defer self.allocator.free(code);
                try writeTagged(current_transport, tag, .ok, code, "REPLACE completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.close)) {
                if (session.selected) |mailbox| {
                    _ = try expungeMailbox(current_transport, mailbox, true);
                }
                session.selected = null;
                if (session.user != null) session.state = .authenticated;
                session.read_only = false;
                try writeTagged(current_transport, tag, .ok, null, "CLOSE completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.search)) {
                if (session.selected == null or args.len == 0) {
                    try writeTagged(current_transport, tag, .bad, null, "SEARCH requires selected mailbox and criteria");
                    continue;
                }
                var criteria = try parseSearchCriteria(self.allocator, args);
                defer freeSearchCriteria(self.allocator, &criteria);
                try self.writeSearchResults(current_transport, session.selected.?, uid_mode, criteria);
                try writeTagged(current_transport, tag, .ok, null, "SEARCH completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.fetch)) {
                if (session.selected == null or args.len < 2) {
                    try writeTagged(current_transport, tag, .bad, null, "FETCH requires message set and items");
                    continue;
                }
                var set = imap.NumSet.parse(self.allocator, if (uid_mode) .uid else .seq, args[0].value) catch {
                    try writeTagged(current_transport, tag, .bad, null, "invalid message set");
                    continue;
                };
                defer set.deinit();
                try self.writeFetchResults(current_transport, session.selected.?, uid_mode, &set, args[1].value);
                try writeTagged(current_transport, tag, .ok, null, "FETCH completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.store)) {
                if (session.selected == null or session.read_only or args.len < 3) {
                    try writeTagged(current_transport, tag, .bad, null, "STORE requires selected writable mailbox");
                    continue;
                }
                var set = imap.NumSet.parse(self.allocator, if (uid_mode) .uid else .seq, args[0].value) catch {
                    try writeTagged(current_transport, tag, .bad, null, "invalid message set");
                    continue;
                };
                defer set.deinit();

                const op = args[1].value;
                const action = if (std.mem.startsWith(u8, op, "+")) imap.StoreAction.add else if (std.mem.startsWith(u8, op, "-")) imap.StoreAction.remove else imap.StoreAction.replace;
                const silent = std.mem.indexOf(u8, op, ".SILENT") != null;
                var flags = std.ArrayList([]const u8).empty;
                defer freeOwnedStrings(self.allocator, &flags);
                try parseFlagList(self.allocator, args[2].value, &flags);
                try self.applyStore(current_transport, session.selected.?, uid_mode, &set, action, silent, flags.items);
                try writeTagged(current_transport, tag, .ok, null, "STORE completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.copy) or std.ascii.eqlIgnoreCase(command_name, imap.commands.move)) {
                if (session.selected == null or args.len < 2 or session.user == null) {
                    try writeTagged(current_transport, tag, .bad, null, "COPY/MOVE requires selected mailbox and destination");
                    continue;
                }
                var set = imap.NumSet.parse(self.allocator, if (uid_mode) .uid else .seq, args[0].value) catch {
                    try writeTagged(current_transport, tag, .bad, null, "invalid message set");
                    continue;
                };
                defer set.deinit();

                const dest = session.user.?.getMailbox(args[1].value) orelse {
                    try writeTagged(current_transport, tag, .no, null, "destination mailbox not found");
                    continue;
                };

                var source_uids = std.ArrayList(imap.UID).empty;
                defer source_uids.deinit(self.allocator);
                var dest_uids = std.ArrayList(imap.UID).empty;
                defer dest_uids.deinit(self.allocator);

                for (session.selected.?.messages.items, 0..) |*message, index| {
                    const id = if (uid_mode) message.uid else @as(u32, @intCast(index + 1));
                    if (!set.contains(id)) continue;
                    const new_uid = try dest.appendMessage(message.body, message.flags.items, message.internal_date_unix);
                    try source_uids.append(self.allocator, message.uid);
                    try dest_uids.append(self.allocator, new_uid);
                    if (std.ascii.eqlIgnoreCase(command_name, imap.commands.move)) {
                        _ = try message.addFlag(session.selected.?.allocator, imap.flags.deleted);
                    }
                }

                const src_text = try joinUids(self.allocator, source_uids.items);
                defer self.allocator.free(src_text);
                const dst_text = try joinUids(self.allocator, dest_uids.items);
                defer self.allocator.free(dst_text);
                const code = try std.fmt.allocPrint(self.allocator, "COPYUID {d} {s} {s}", .{ dest.uid_validity, src_text, dst_text });
                defer self.allocator.free(code);
                if (std.ascii.eqlIgnoreCase(command_name, imap.commands.move)) {
                    _ = try expungeMailbox(current_transport, session.selected.?, false);
                }
                try writeTagged(current_transport, tag, .ok, code, if (std.ascii.eqlIgnoreCase(command_name, imap.commands.move)) "MOVE completed" else "COPY completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.expunge)) {
                if (session.selected == null or session.read_only) {
                    try writeTagged(current_transport, tag, .bad, null, "EXPUNGE requires selected writable mailbox");
                    continue;
                }
                _ = try expungeMailbox(current_transport, session.selected.?, false);
                try writeTagged(current_transport, tag, .ok, null, "EXPUNGE completed");
                continue;
            }

            try writeTagged(current_transport, tag, .bad, null, "unsupported command");
        }
    }

    /// Serve a plain transport (no TLS upgrade support).
    pub fn serveTransport(self: *Server, t: wire.Transport) !void {
        try self.serveConnection(t, null, false);
    }

    /// Serve a TCP stream with STARTTLS upgrade support.
    pub fn serveStream(self: *Server, stream: *std.net.Stream) !void {
        try self.serveConnection(wire.Transport.fromNetStream(stream), stream.*, false);
    }

    /// Listen on the given address and serve plain TCP connections.
    pub fn listenAndServe(self: *Server, bind: []const u8) !void {
        var address = try std.net.Address.parseIpAndPort(bind);
        var listener = try address.listen(.{ .reuse_address = true });
        defer listener.deinit();

        while (true) {
            var connection = try listener.accept();
            defer connection.stream.close();
            try self.serveStream(&connection.stream);
        }
    }

    /// Listen on the given address and serve implicit TLS connections.
    /// Uses the configured tls_upgrade_fn to wrap each accepted connection.
    pub fn listenAndServeTls(self: *Server, bind: []const u8) !void {
        const upgrade_fn = self.options.tls_upgrade_fn orelse return error.NoTlsConfig;
        const upgrade_ctx = self.options.tls_upgrade_ctx orelse return error.MissingTlsContext;

        var address = try std.net.Address.parseIpAndPort(bind);
        var listener = try address.listen(.{ .reuse_address = true });
        defer listener.deinit();

        while (true) {
            var connection = try listener.accept();
            defer connection.stream.close();
            const tls_transport = try upgrade_fn(upgrade_ctx, connection.stream);
            try self.serveConnection(tls_transport, connection.stream, true);
        }
    }

    fn handleList(self: *Server, transport: wire.Transport, user: *memstore.User, _: []const u8, pattern: []const u8) !void {
        var it = user.mailboxes.iterator();
        while (it.next()) |entry| {
            const mailbox = entry.value_ptr.*;
            if (!memstore.matchesPattern(mailbox.name, pattern)) continue;
            var attrs = std.ArrayList(u8).empty;
            defer attrs.deinit(self.allocator);
            if (mailbox.subscribed) try attrs.appendSlice(self.allocator, "\\Subscribed ");
            const attr_text = if (attrs.items.len == 0) "" else attrs.items[0 .. attrs.items.len - 1];
            try transport.print("* LIST ({s}) \"/\" \"{s}\"\r\n", .{ attr_text, mailbox.name });
        }
    }

    fn handleLsub(self: *Server, transport: wire.Transport, user: *memstore.User, _: []const u8, pattern: []const u8) !void {
        var it = user.mailboxes.iterator();
        while (it.next()) |entry| {
            const mailbox = entry.value_ptr.*;
            if (!mailbox.subscribed) continue;
            if (!memstore.matchesPattern(mailbox.name, pattern)) continue;

            var attrs = std.ArrayList(u8).empty;
            defer attrs.deinit(self.allocator);
            try attrs.appendSlice(self.allocator, "\\Subscribed");
            try transport.print("* LSUB ({s}) \"/\" \"{s}\"\r\n", .{ attrs.items, mailbox.name });
        }
    }

    fn writeSelectData(self: *Server, transport: wire.Transport, mailbox: *memstore.Mailbox, read_only: bool) !void {
        _ = self;
        try transport.print("* FLAGS ({s} {s} {s} {s} {s})\r\n", .{
            imap.flags.seen,
            imap.flags.answered,
            imap.flags.flagged,
            imap.flags.deleted,
            imap.flags.draft,
        });
        try transport.print("* {d} EXISTS\r\n", .{mailbox.messages.items.len});
        try transport.print("* {d} RECENT\r\n", .{mailbox.countRecent()});
        try transport.print("* OK [UIDVALIDITY {d}] UIDs valid\r\n", .{mailbox.uid_validity});
        try transport.print("* OK [UIDNEXT {d}] Predicted next UID\r\n", .{mailbox.next_uid});
        if (mailbox.firstUnseenSeq()) |seq| {
            try transport.print("* OK [UNSEEN {d}] first unseen\r\n", .{seq});
        }
        try transport.print("* OK [PERMANENTFLAGS ({s} {s} {s} {s} {s})] flags permitted\r\n", .{
            imap.flags.seen,
            imap.flags.answered,
            imap.flags.flagged,
            imap.flags.deleted,
            imap.flags.draft,
        });
        _ = read_only;
    }

    fn writeStatusData(self: *Server, transport: wire.Transport, mailbox: *memstore.Mailbox, items_token: []const u8) !void {
        _ = self;
        const items = stripOuter(items_token, '(', ')');
        var it = std.mem.tokenizeAny(u8, items, " ");
        var buf: [256]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        const writer = stream.writer();
        try writer.print("* STATUS {s} (", .{mailbox.name});
        var first = true;
        while (it.next()) |item| {
            if (!first) try writer.writeByte(' ');
            first = false;
            if (std.ascii.eqlIgnoreCase(item, "MESSAGES")) {
                try writer.print("MESSAGES {d}", .{mailbox.messages.items.len});
            } else if (std.ascii.eqlIgnoreCase(item, "RECENT")) {
                try writer.print("RECENT {d}", .{mailbox.countRecent()});
            } else if (std.ascii.eqlIgnoreCase(item, "UNSEEN")) {
                try writer.print("UNSEEN {d}", .{mailbox.firstUnseenSeq() orelse 0});
            } else if (std.ascii.eqlIgnoreCase(item, "UIDNEXT")) {
                try writer.print("UIDNEXT {d}", .{mailbox.next_uid});
            } else if (std.ascii.eqlIgnoreCase(item, "UIDVALIDITY")) {
                try writer.print("UIDVALIDITY {d}", .{mailbox.uid_validity});
            }
        }
        try writer.writeAll(")\r\n");
        try transport.writeAll(stream.getWritten());
    }

    fn writeSearchResults(self: *Server, transport: wire.Transport, mailbox: *memstore.Mailbox, uid_mode: bool, criteria: imap.SearchCriteria) !void {
        var matches = std.ArrayList(u32).empty;
        defer matches.deinit(self.allocator);

        var uid_filter: ?imap.NumSet = null;
        defer if (uid_filter) |*set| set.deinit();
        if (criteria.uid_set) |uid_set| {
            uid_filter = try imap.NumSet.parse(self.allocator, .uid, uid_set);
        }

        for (mailbox.messages.items, 0..) |message, index| {
            if (uid_filter) |set| {
                if (!set.contains(message.uid)) continue;
            }
            if (!messageMatches(message, criteria)) continue;
            try matches.append(self.allocator, if (uid_mode) message.uid else @as(u32, @intCast(index + 1)));
        }

        const joined = try joinU32sSpace(self.allocator, matches.items);
        defer self.allocator.free(joined);
        if (joined.len == 0) {
            try transport.writeAll("* SEARCH\r\n");
        } else {
            try transport.print("* SEARCH {s}\r\n", .{joined});
        }
    }

    fn writeFetchResults(self: *Server, transport: wire.Transport, mailbox: *memstore.Mailbox, uid_mode: bool, set: *const imap.NumSet, items_token: []const u8) !void {
        const items = stripOuter(items_token, '(', ')');
        for (mailbox.messages.items, 0..) |message, index| {
            const seq = @as(u32, @intCast(index + 1));
            const selector = if (uid_mode) message.uid else seq;
            if (!set.contains(selector)) continue;

            var buf: [2048]u8 = undefined;
            var stream = std.io.fixedBufferStream(&buf);
            const writer = stream.writer();
            try writer.print("* {d} FETCH (", .{seq});
            var parts = std.mem.tokenizeAny(u8, items, " ");
            var first = true;
            while (parts.next()) |part| {
                if (!first) try writer.writeByte(' ');
                first = false;
                if (std.ascii.eqlIgnoreCase(part, "FLAGS")) {
                    try writer.writeAll("FLAGS (");
                    for (message.flags.items, 0..) |flag, flag_index| {
                        if (flag_index != 0) try writer.writeByte(' ');
                        try writer.writeAll(flag);
                    }
                    try writer.writeByte(')');
                } else if (std.ascii.eqlIgnoreCase(part, "UID")) {
                    try writer.print("UID {d}", .{message.uid});
                } else if (std.ascii.eqlIgnoreCase(part, "RFC822.SIZE")) {
                    try writer.print("RFC822.SIZE {d}", .{message.body.len});
                } else if (std.ascii.eqlIgnoreCase(part, "INTERNALDATE")) {
                    var date_buf: [64]u8 = undefined;
                    const formatted = try imap.formatInternalDateUnix(&date_buf, message.internal_date_unix);
                    try writer.print("INTERNALDATE \"{s}\"", .{formatted});
                } else if (std.ascii.eqlIgnoreCase(part, "BODY[]") or std.ascii.eqlIgnoreCase(part, "BODY.PEEK[]")) {
                    const escaped = try escapeForQuoted(self.allocator, message.body);
                    defer self.allocator.free(escaped);
                    try writer.print("BODY[] \"{s}\"", .{escaped});
                }
            }
            try writer.writeAll(")\r\n");
            try transport.writeAll(stream.getWritten());
        }
    }

    fn applyStore(self: *Server, transport: wire.Transport, mailbox: *memstore.Mailbox, uid_mode: bool, set: *const imap.NumSet, action: imap.StoreAction, silent: bool, flags: []const []const u8) !void {
        for (mailbox.messages.items, 0..) |*message, index| {
            const selector = if (uid_mode) message.uid else @as(u32, @intCast(index + 1));
            if (!set.contains(selector)) continue;
            switch (action) {
                .replace => try message.replaceFlags(mailbox.allocator, flags),
                .add => for (flags) |flag| try message.addFlag(mailbox.allocator, flag),
                .remove => for (flags) |flag| {
                    _ = message.removeFlag(mailbox.allocator, flag);
                },
            }
            if (!silent) {
                var buf: [512]u8 = undefined;
                var stream = std.io.fixedBufferStream(&buf);
                const writer = stream.writer();
                try writer.print("* {d} FETCH (FLAGS (", .{@as(u32, @intCast(index + 1))});
                for (message.flags.items, 0..) |flag, flag_index| {
                    if (flag_index != 0) try writer.writeByte(' ');
                    try writer.writeAll(flag);
                }
                try writer.print(") UID {d})\r\n", .{message.uid});
                try transport.writeAll(stream.getWritten());
            }
        }
        _ = self;
    }

    fn writeAclData(self: *Server, transport: wire.Transport, mailbox: *memstore.Mailbox, user: *memstore.User) !void {
        _ = self;
        try transport.print("* ACL {s} {s} lrswipdkxtea", .{ mailbox.name, user.username });
        var it = mailbox.acl.iterator();
        while (it.next()) |entry| {
            try transport.print(" {s} {s}", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        try transport.writeAll("\r\n");
    }

    fn writeQuota(self: *Server, transport: wire.Transport, user: *memstore.User) !void {
        _ = self;
        try transport.print(
            "* QUOTA \"{s}\" (STORAGE {d} {d} MESSAGE {d} {d})\r\n",
            .{
                user.quota_root,
                user.quotaStorageUsage(),
                user.quota_storage_limit,
                user.quotaMessageUsage(),
                user.quota_message_limit,
            },
        );
    }

    fn writeMetadata(self: *Server, transport: wire.Transport, mailbox: *memstore.Mailbox, requested: ?Token) !void {
        try transport.print("* METADATA {s} (", .{mailbox.name});
        var first = true;

        if (requested) |token| {
            var items = try tokenizeLine(self.allocator, token.value);
            defer items.deinit(self.allocator);
            for (items.items) |item| {
                if (!first) try transport.writeAll(" ");
                first = false;
                try transport.print("\"{s}\" ", .{item.value});
                if (mailbox.metadata.get(item.value)) |value_opt| {
                    if (value_opt) |value| {
                        const escaped = try escapeForQuoted(self.allocator, value);
                        defer self.allocator.free(escaped);
                        try transport.print("\"{s}\"", .{escaped});
                    } else {
                        try transport.writeAll("NIL");
                    }
                } else {
                    try transport.writeAll("NIL");
                }
            }
        } else {
            var it = mailbox.metadata.iterator();
            while (it.next()) |entry| {
                if (!first) try transport.writeAll(" ");
                first = false;
                try transport.print("\"{s}\" ", .{entry.key_ptr.*});
                if (entry.value_ptr.*) |value| {
                    const escaped = try escapeForQuoted(self.allocator, value);
                    defer self.allocator.free(escaped);
                    try transport.print("\"{s}\"", .{escaped});
                } else {
                    try transport.writeAll("NIL");
                }
            }
        }

        try transport.writeAll(")\r\n");
    }
};

pub const Placeholder = Server;

const SessionState = struct {
    state: imap.ConnState = .not_authenticated,
    user: ?*memstore.User = null,
    selected: ?*memstore.Mailbox = null,
    read_only: bool = false,
    is_tls: bool = false,
    underlying_stream: ?std.net.Stream = null,

    fn unselect(self: *SessionState) void {
        self.selected = null;
        self.read_only = false;
        self.state = .authenticated;
    }
};

const TokenKind = enum {
    atom,
    quoted,
    group,
};

const Token = struct {
    value: []const u8,
    kind: TokenKind,
};

fn readAuthResponseAlloc(allocator: std.mem.Allocator, reader: *wire.LineReader, transport: wire.Transport, initial: ?[]const u8, challenge: ?[]const u8) ![]u8 {
    if (initial) |value| return allocator.dupe(u8, value);
    if (challenge) |encoded| {
        try transport.print("+ {s}\r\n", .{encoded});
    } else {
        try transport.writeAll("+ \r\n");
    }
    return reader.readLineAlloc();
}

fn fixedCramMd5ChallengeAlloc(allocator: std.mem.Allocator) ![]u8 {
    const raw = "<imap.zig@localhost>";
    const out = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(raw.len));
    _ = std.base64.standard.Encoder.encode(out, raw);
    return out;
}

fn tokenizeLine(allocator: std.mem.Allocator, line: []const u8) !std.ArrayList(Token) {
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

fn parseLiteralMarker(token: []const u8) !usize {
    if (token.len < 3 or token[0] != '{' or token[token.len - 1] != '}') return error.InvalidLiteral;
    return std.fmt.parseInt(usize, token[1 .. token.len - 1], 10);
}

fn tokensHaveList(token: Token) bool {
    return token.kind == .group;
}

fn parseFlagList(allocator: std.mem.Allocator, token: []const u8, out: *std.ArrayList([]const u8)) !void {
    const inner = stripOuter(token, '(', ')');
    var it = std.mem.tokenizeAny(u8, inner, " ");
    while (it.next()) |flag| {
        try out.append(allocator, try allocator.dupe(u8, flag));
    }
}

fn stripOuter(value: []const u8, open: u8, close: u8) []const u8 {
    if (value.len >= 2 and value[0] == open and value[value.len - 1] == close) {
        return value[1 .. value.len - 1];
    }
    return value;
}

fn parseSearchCriteria(allocator: std.mem.Allocator, args: []const Token) !imap.SearchCriteria {
    var criteria = imap.SearchCriteria{};
    var explicit = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const token = args[index].value;
        if (std.ascii.eqlIgnoreCase(token, "ALL")) {
            explicit = true;
        } else if (std.ascii.eqlIgnoreCase(token, "SEEN")) {
            criteria.seen = true;
            explicit = true;
        } else if (std.ascii.eqlIgnoreCase(token, "UNSEEN")) {
            criteria.seen = false;
            explicit = true;
        } else if (std.ascii.eqlIgnoreCase(token, "ANSWERED")) {
            criteria.answered = true;
            explicit = true;
        } else if (std.ascii.eqlIgnoreCase(token, "UNANSWERED")) {
            criteria.answered = false;
            explicit = true;
        } else if (std.ascii.eqlIgnoreCase(token, "FLAGGED")) {
            criteria.flagged = true;
            explicit = true;
        } else if (std.ascii.eqlIgnoreCase(token, "UNFLAGGED")) {
            criteria.flagged = false;
            explicit = true;
        } else if (std.ascii.eqlIgnoreCase(token, "DELETED")) {
            criteria.deleted = true;
            explicit = true;
        } else if (std.ascii.eqlIgnoreCase(token, "UNDELETED")) {
            criteria.deleted = false;
            explicit = true;
        } else if (std.ascii.eqlIgnoreCase(token, "DRAFT")) {
            criteria.draft = true;
            explicit = true;
        } else if (std.ascii.eqlIgnoreCase(token, "UNDRAFT")) {
            criteria.draft = false;
            explicit = true;
        } else if (std.ascii.eqlIgnoreCase(token, "SUBJECT") and index + 1 < args.len) {
            criteria.subject = try allocator.dupe(u8, args[index + 1].value);
            explicit = true;
            index += 1;
        } else if (std.ascii.eqlIgnoreCase(token, "BODY") and index + 1 < args.len) {
            criteria.body = try allocator.dupe(u8, args[index + 1].value);
            explicit = true;
            index += 1;
        } else if (std.ascii.eqlIgnoreCase(token, "TEXT") and index + 1 < args.len) {
            criteria.text = try allocator.dupe(u8, args[index + 1].value);
            explicit = true;
            index += 1;
        } else if (std.ascii.eqlIgnoreCase(token, "FROM") and index + 1 < args.len) {
            criteria.from = try allocator.dupe(u8, args[index + 1].value);
            explicit = true;
            index += 1;
        } else if (std.ascii.eqlIgnoreCase(token, "TO") and index + 1 < args.len) {
            criteria.to = try allocator.dupe(u8, args[index + 1].value);
            explicit = true;
            index += 1;
        } else if (std.ascii.eqlIgnoreCase(token, "UID") and index + 1 < args.len) {
            criteria.uid_set = try allocator.dupe(u8, args[index + 1].value);
            explicit = true;
            index += 1;
        } else if (std.ascii.eqlIgnoreCase(token, "LARGER") and index + 1 < args.len) {
            criteria.larger = std.fmt.parseInt(u64, args[index + 1].value, 10) catch null;
            explicit = true;
            index += 1;
        } else if (std.ascii.eqlIgnoreCase(token, "SMALLER") and index + 1 < args.len) {
            criteria.smaller = std.fmt.parseInt(u64, args[index + 1].value, 10) catch null;
            explicit = true;
            index += 1;
        } else if (std.ascii.eqlIgnoreCase(token, "HEADER") and index + 2 < args.len) {
            criteria.header = .{
                try allocator.dupe(u8, args[index + 1].value),
                try allocator.dupe(u8, args[index + 2].value),
            };
            explicit = true;
            index += 2;
        } else if (std.ascii.eqlIgnoreCase(token, "NOT")) {
            // Skip NOT handling for now - would need recursive parsing
            explicit = true;
        } else if (std.ascii.eqlIgnoreCase(token, "OR")) {
            // Skip OR handling for now - would need recursive parsing
            explicit = true;
        } else if (std.ascii.eqlIgnoreCase(token, "KEYWORD") and index + 1 < args.len) {
            criteria.keyword = try allocator.dupe(u8, args[index + 1].value);
            explicit = true;
            index += 1;
        } else if (std.ascii.eqlIgnoreCase(token, "UNKEYWORD") and index + 1 < args.len) {
            criteria.unkeyword = try allocator.dupe(u8, args[index + 1].value);
            explicit = true;
            index += 1;
        } else if (std.ascii.eqlIgnoreCase(token, "SINCE") and index + 1 < args.len) {
            criteria.since = std.fmt.parseInt(u64, args[index + 1].value, 10) catch null;
            explicit = true;
            index += 1;
        } else if (std.ascii.eqlIgnoreCase(token, "BEFORE") and index + 1 < args.len) {
            criteria.before = std.fmt.parseInt(u64, args[index + 1].value, 10) catch null;
            explicit = true;
            index += 1;
        } else if (std.ascii.eqlIgnoreCase(token, "ON") and index + 1 < args.len) {
            criteria.on = std.fmt.parseInt(u64, args[index + 1].value, 10) catch null;
            explicit = true;
            index += 1;
        } else if (std.ascii.eqlIgnoreCase(token, "SENTSINCE") and index + 1 < args.len) {
            criteria.sent_since = std.fmt.parseInt(u64, args[index + 1].value, 10) catch null;
            explicit = true;
            index += 1;
        } else if (std.ascii.eqlIgnoreCase(token, "SENTBEFORE") and index + 1 < args.len) {
            criteria.sent_before = std.fmt.parseInt(u64, args[index + 1].value, 10) catch null;
            explicit = true;
            index += 1;
        } else if (std.ascii.eqlIgnoreCase(token, "SENTON") and index + 1 < args.len) {
            criteria.sent_on = std.fmt.parseInt(u64, args[index + 1].value, 10) catch null;
            explicit = true;
            index += 1;
        }
    }
    criteria.all = !explicit;
    return criteria;
}

fn freeSearchCriteria(allocator: std.mem.Allocator, criteria: *imap.SearchCriteria) void {
    if (criteria.subject) |value| allocator.free(value);
    if (criteria.body) |value| allocator.free(value);
    if (criteria.text) |value| allocator.free(value);
    if (criteria.from) |value| allocator.free(value);
    if (criteria.to) |value| allocator.free(value);
    if (criteria.uid_set) |value| allocator.free(value);
    if (criteria.header) |header| {
        allocator.free(header[0]);
        allocator.free(header[1]);
    }
    if (criteria.keyword) |value| allocator.free(value);
    if (criteria.unkeyword) |value| allocator.free(value);
    criteria.* = undefined;
}

fn messageMatches(message: memstore.Message, criteria: imap.SearchCriteria) bool {
    if (criteria.seen) |value| if (message.hasFlag(imap.flags.seen) != value) return false;
    if (criteria.answered) |value| if (message.hasFlag(imap.flags.answered) != value) return false;
    if (criteria.flagged) |value| if (message.hasFlag(imap.flags.flagged) != value) return false;
    if (criteria.deleted) |value| if (message.hasFlag(imap.flags.deleted) != value) return false;
    if (criteria.draft) |value| if (message.hasFlag(imap.flags.draft) != value) return false;

    if (criteria.subject) |needle| {
        const subject = extractHeader(message.body, "Subject");
        if (!containsAsciiNoCase(subject, needle)) return false;
    }
    if (criteria.from) |needle| {
        const value = extractHeader(message.body, "From");
        if (!containsAsciiNoCase(value, needle)) return false;
    }
    if (criteria.to) |needle| {
        const value = extractHeader(message.body, "To");
        if (!containsAsciiNoCase(value, needle)) return false;
    }
    if (criteria.body) |needle| {
        if (!containsAsciiNoCase(message.body, needle)) return false;
    }
    if (criteria.text) |needle| {
        if (!containsAsciiNoCase(message.body, needle)) return false;
    }
    if (criteria.larger) |min_size| {
        if (message.body.len <= min_size) return false;
    }
    if (criteria.smaller) |max_size| {
        if (message.body.len >= max_size) return false;
    }
    if (criteria.header) |header| {
        const header_value = extractHeader(message.body, header[0]);
        if (!containsAsciiNoCase(header_value, header[1])) return false;
    }
    if (criteria.keyword) |flag_name| {
        if (!message.hasFlag(flag_name)) return false;
    }
    if (criteria.unkeyword) |flag_name| {
        if (message.hasFlag(flag_name)) return false;
    }
    if (criteria.since) |timestamp| {
        if (message.internal_date_unix < timestamp) return false;
    }
    if (criteria.before) |timestamp| {
        if (message.internal_date_unix >= timestamp) return false;
    }
    if (criteria.on) |timestamp| {
        // Check if message date falls within the same day (86400 seconds)
        if (message.internal_date_unix < timestamp or message.internal_date_unix >= timestamp + 86400) return false;
    }
    return true;
}

fn parseSortCriteria(allocator: std.mem.Allocator, token: Token) ![]imap.SortCriterion {
    if (token.kind != .group) return error.InvalidSortCriteria;
    var pieces = try tokenizeLine(allocator, token.value);
    defer pieces.deinit(allocator);

    var out: std.ArrayList(imap.SortCriterion) = .empty;
    errdefer out.deinit(allocator);

    var index: usize = 0;
    while (index < pieces.items.len) : (index += 1) {
        var criterion = imap.SortCriterion{};
        if (std.ascii.eqlIgnoreCase(pieces.items[index].value, "REVERSE")) {
            criterion.reverse = true;
            index += 1;
            if (index >= pieces.items.len) return error.InvalidSortCriteria;
        }

        criterion.key = parseSortKey(pieces.items[index].value) orelse return error.InvalidSortCriteria;
        try out.append(allocator, criterion);
    }

    return out.toOwnedSlice(allocator);
}

fn parseSortKey(value: []const u8) ?imap.SortKey {
    if (std.ascii.eqlIgnoreCase(value, "ARRIVAL")) return .arrival;
    if (std.ascii.eqlIgnoreCase(value, "CC")) return .cc;
    if (std.ascii.eqlIgnoreCase(value, "DATE")) return .date;
    if (std.ascii.eqlIgnoreCase(value, "FROM")) return .from;
    if (std.ascii.eqlIgnoreCase(value, "SIZE")) return .size;
    if (std.ascii.eqlIgnoreCase(value, "SUBJECT")) return .subject;
    if (std.ascii.eqlIgnoreCase(value, "TO")) return .to;
    if (std.ascii.eqlIgnoreCase(value, "DISPLAYFROM")) return .display_from;
    if (std.ascii.eqlIgnoreCase(value, "DISPLAYTO")) return .display_to;
    return null;
}

fn sortMailbox(allocator: std.mem.Allocator, mailbox: *memstore.Mailbox, uid_mode: bool, criteria: []const imap.SortCriterion, search: imap.SearchCriteria) ![]u32 {
    var indices: std.ArrayList(usize) = .empty;
    defer indices.deinit(allocator);
    for (mailbox.messages.items, 0..) |message, index| {
        if (messageMatches(message, search)) try indices.append(allocator, index);
    }

    var i: usize = 0;
    while (i < indices.items.len) : (i += 1) {
        var j: usize = i + 1;
        while (j < indices.items.len) : (j += 1) {
            if (compareMessages(mailbox, indices.items[i], indices.items[j], criteria) > 0) {
                const tmp = indices.items[i];
                indices.items[i] = indices.items[j];
                indices.items[j] = tmp;
            }
        }
    }

    const ids = try allocator.alloc(u32, indices.items.len);
    for (indices.items, 0..) |index, out_index| {
        ids[out_index] = if (uid_mode) mailbox.messages.items[index].uid else @as(u32, @intCast(index + 1));
    }
    return ids;
}

fn compareMessages(mailbox: *memstore.Mailbox, left_index: usize, right_index: usize, criteria: []const imap.SortCriterion) i32 {
    const left = mailbox.messages.items[left_index];
    const right = mailbox.messages.items[right_index];
    for (criteria) |criterion| {
        var cmp = compareByKey(left, right, criterion.key);
        if (criterion.reverse) cmp = -cmp;
        if (cmp != 0) return cmp;
    }
    return compareU32(@as(u32, @intCast(left_index)), @as(u32, @intCast(right_index)));
}

fn compareByKey(left: memstore.Message, right: memstore.Message, key: imap.SortKey) i32 {
    return switch (key) {
        .arrival, .date => compareU64(left.internal_date_unix, right.internal_date_unix),
        .size => compareU64(left.body.len, right.body.len),
        .subject => compareText(extractHeader(left.body, "Subject"), extractHeader(right.body, "Subject")),
        .from, .display_from => compareText(extractHeader(left.body, "From"), extractHeader(right.body, "From")),
        .to, .display_to => compareText(extractHeader(left.body, "To"), extractHeader(right.body, "To")),
        .cc => compareText(extractHeader(left.body, "Cc"), extractHeader(right.body, "Cc")),
    };
}

fn threadMailbox(allocator: std.mem.Allocator, mailbox: *memstore.Mailbox, uid_mode: bool, algorithm: imap.ThreadAlgorithm, search: imap.SearchCriteria) ![]u8 {
    var included: std.ArrayList(usize) = .empty;
    defer included.deinit(allocator);
    for (mailbox.messages.items, 0..) |message, index| {
        if (messageMatches(message, search)) try included.append(allocator, index);
    }

    return switch (algorithm) {
        .orderedsubject => threadBySubject(allocator, mailbox, included.items, uid_mode),
        .references => threadByReferences(allocator, mailbox, included.items, uid_mode),
    };
}

fn threadBySubject(allocator: std.mem.Allocator, mailbox: *memstore.Mailbox, indices: []const usize, uid_mode: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var used = try allocator.alloc(bool, indices.len);
    defer allocator.free(used);
    @memset(used, false);

    for (indices, 0..) |index, outer| {
        if (used[outer]) continue;
        used[outer] = true;
        const subject = normalizeSubject(extractHeader(mailbox.messages.items[index].body, "Subject"));
        try out.append(allocator, '(');
        try appendThreadId(out.writer(allocator), mailbox, index, uid_mode);
        for (indices[outer + 1 ..], outer + 1..) |other_index, inner| {
            const other_subject = normalizeSubject(extractHeader(mailbox.messages.items[other_index].body, "Subject"));
            if (!std.ascii.eqlIgnoreCase(subject, other_subject)) continue;
            used[inner] = true;
            try out.append(allocator, ' ');
            try appendThreadId(out.writer(allocator), mailbox, other_index, uid_mode);
        }
        try out.append(allocator, ')');
    }
    return out.toOwnedSlice(allocator);
}

fn threadByReferences(allocator: std.mem.Allocator, mailbox: *memstore.Mailbox, indices: []const usize, uid_mode: bool) ![]u8 {
    var message_ids = std.StringHashMap(usize).init(allocator);
    defer {
        var it = message_ids.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        message_ids.deinit();
    }

    for (indices) |index| {
        const message_id = extractHeader(mailbox.messages.items[index].body, "Message-ID");
        if (message_id.len == 0) continue;
        try message_ids.put(try allocator.dupe(u8, message_id), index);
    }

    const parent = try allocator.alloc(?usize, mailbox.messages.items.len);
    defer allocator.free(parent);
    @memset(parent, null);
    for (indices) |index| {
        const refs = extractHeader(mailbox.messages.items[index].body, "References");
        const reply_to = extractHeader(mailbox.messages.items[index].body, "In-Reply-To");
        const candidate = if (refs.len != 0) lastReference(refs) else reply_to;
        if (candidate.len == 0) continue;
        parent[index] = message_ids.get(candidate);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var first = true;
    for (indices) |index| {
        if (parent[index] != null) continue;
        if (!first) try out.append(allocator, ' ');
        first = false;
        try renderThreadNode(out.writer(allocator), mailbox, indices, parent, index, uid_mode);
    }
    return out.toOwnedSlice(allocator);
}

fn renderThreadNode(writer: anytype, mailbox: *memstore.Mailbox, indices: []const usize, parent: []const ?usize, current: usize, uid_mode: bool) !void {
    try writer.writeByte('(');
    try appendThreadId(writer, mailbox, current, uid_mode);
    for (indices) |candidate| {
        if (parent[candidate] != current) continue;
        try writer.writeByte(' ');
        try renderThreadNode(writer, mailbox, indices, parent, candidate, uid_mode);
    }
    try writer.writeByte(')');
}

fn appendThreadId(writer: anytype, mailbox: *memstore.Mailbox, index: usize, uid_mode: bool) !void {
    try std.fmt.format(writer, "{d}", .{if (uid_mode) mailbox.messages.items[index].uid else index + 1});
}

fn normalizeSubject(subject: []const u8) []const u8 {
    var value = std.mem.trim(u8, subject, " \t");
    while (value.len >= 3 and std.ascii.eqlIgnoreCase(value[0..3], "Re:")) {
        value = std.mem.trim(u8, value[3..], " \t");
    }
    return value;
}

fn lastReference(refs: []const u8) []const u8 {
    var it = std.mem.tokenizeAny(u8, refs, " \t");
    var last: []const u8 = "";
    while (it.next()) |item| last = item;
    return last;
}

fn applyQuotaResources(user: *memstore.User, token: Token) !void {
    if (token.kind != .group) return error.InvalidQuotaResources;
    var items = try tokenizeLine(user.allocator, token.value);
    defer items.deinit(user.allocator);
    var index: usize = 0;
    while (index + 1 < items.items.len) : (index += 2) {
        const resource = items.items[index].value;
        const limit = try std.fmt.parseInt(u64, items.items[index + 1].value, 10);
        if (std.ascii.eqlIgnoreCase(resource, "STORAGE")) user.quota_storage_limit = limit;
        if (std.ascii.eqlIgnoreCase(resource, "MESSAGE")) user.quota_message_limit = limit;
    }
}

fn applyMetadataUpdates(allocator: std.mem.Allocator, mailbox: *memstore.Mailbox, token: Token) !void {
    if (token.kind != .group) return error.InvalidMetadata;
    var items = try tokenizeLine(allocator, token.value);
    defer items.deinit(allocator);
    var index: usize = 0;
    while (index + 1 < items.items.len) : (index += 2) {
        const name = items.items[index].value;
        const value = items.items[index + 1].value;
        if (std.ascii.eqlIgnoreCase(value, "NIL")) {
            _ = mailbox.removeMetadata(name);
        } else {
            try mailbox.setMetadata(name, value);
        }
    }
}

fn compareText(left: []const u8, right: []const u8) i32 {
    const len = @min(left.len, right.len);
    var index: usize = 0;
    while (index < len) : (index += 1) {
        const a = std.ascii.toLower(left[index]);
        const b = std.ascii.toLower(right[index]);
        if (a < b) return -1;
        if (a > b) return 1;
    }
    return compareU64(left.len, right.len);
}

fn compareU64(left: u64, right: u64) i32 {
    if (left < right) return -1;
    if (left > right) return 1;
    return 0;
}

fn compareU32(left: u32, right: u32) i32 {
    if (left < right) return -1;
    if (left > right) return 1;
    return 0;
}

fn extractHeader(body: []const u8, header_name: []const u8) []const u8 {
    var it = std.mem.splitSequence(u8, body, "\r\n");
    while (it.next()) |line| {
        if (line.len == 0) break;
        if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
            const name = std.mem.trim(u8, line[0..colon], " ");
            if (std.ascii.eqlIgnoreCase(name, header_name)) {
                return std.mem.trim(u8, line[colon + 1 ..], " ");
            }
        }
    }
    return "";
}

fn containsAsciiNoCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn writeTagged(transport: wire.Transport, tag: []const u8, kind: imap.StatusKind, code: ?[]const u8, text: []const u8) !void {
    const kind_text = switch (kind) {
        .ok => "OK",
        .no => "NO",
        .bad => "BAD",
        .bye => "BYE",
        .preauth => "PREAUTH",
    };
    if (code) |code_text| {
        try transport.print("{s} {s} [{s}] {s}\r\n", .{ tag, kind_text, code_text, text });
    } else {
        try transport.print("{s} {s} {s}\r\n", .{ tag, kind_text, text });
    }
}

fn joinUids(allocator: std.mem.Allocator, values: []const imap.UID) ![]u8 {
    var converted = try allocator.alloc(u32, values.len);
    defer allocator.free(converted);
    for (values, 0..) |value, index| converted[index] = value;
    return joinU32sCsv(allocator, converted);
}

fn joinU32sCsv(allocator: std.mem.Allocator, values: []const u32) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (values, 0..) |value, index| {
        if (index != 0) try out.append(allocator, ',');
        try std.fmt.format(out.writer(allocator), "{d}", .{value});
    }
    return out.toOwnedSlice(allocator);
}

fn joinU32sSpace(allocator: std.mem.Allocator, values: []const u32) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (values, 0..) |value, index| {
        if (index != 0) try out.append(allocator, ' ');
        try std.fmt.format(out.writer(allocator), "{d}", .{value});
    }
    return out.toOwnedSlice(allocator);
}

fn expungeMailbox(transport: wire.Transport, mailbox: *memstore.Mailbox, silent: bool) !u32 {
    var expunged: u32 = 0;
    var index: usize = 0;
    while (index < mailbox.messages.items.len) {
        if (!mailbox.messages.items[index].hasFlag(imap.flags.deleted)) {
            index += 1;
            continue;
        }
        mailbox.messages.items[index].deinit(mailbox.allocator);
        _ = mailbox.messages.orderedRemove(index);
        expunged += 1;
        if (!silent) {
            try transport.print("* {d} EXPUNGE\r\n", .{@as(u32, @intCast(index + 1))});
        }
    }
    return expunged;
}

fn escapeForQuoted(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (value) |byte| {
        switch (byte) {
            '\\', '"' => {
                try out.append(allocator, '\\');
                try out.append(allocator, byte);
            },
            '\r', '\n' => {},
            else => try out.append(allocator, byte),
        }
    }
    return out.toOwnedSlice(allocator);
}

fn freeOwnedStrings(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |item| allocator.free(item);
    list.deinit(allocator);
}
