const std = @import("std");
const imap = @import("../root.zig");
const memstore = @import("../store/memstore.zig");
const wire = @import("../wire/root.zig");

pub const Server = struct {
    allocator: std.mem.Allocator,
    store: *memstore.MemStore,

    pub fn init(allocator: std.mem.Allocator, store: *memstore.MemStore) Server {
        return .{
            .allocator = allocator,
            .store = store,
        };
    }

    pub fn serveTransport(self: *Server, transport: wire.Transport) !void {
        var reader = wire.LineReader.init(self.allocator, transport);
        var session = SessionState{};

        try transport.writeAll("* OK [CAPABILITY IMAP4rev1 UIDPLUS MOVE NAMESPACE ID UNSELECT IDLE ENABLE] imap.zig ready\r\n");

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
                try transport.writeAll("* BAD malformed command\r\n");
                continue;
            }

            const tag = tokens.items[0].value;
            var command_name = tokens.items[1].value;
            var args = tokens.items[2..];
            const uid_mode = std.ascii.eqlIgnoreCase(command_name, "UID");
            if (uid_mode) {
                if (args.len == 0) {
                    try writeTagged(transport, tag, .bad, null, "missing UID subcommand");
                    continue;
                }
                command_name = args[0].value;
                args = args[1..];
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.capability)) {
                try transport.writeAll("* CAPABILITY IMAP4rev1 UIDPLUS MOVE NAMESPACE ID UNSELECT IDLE ENABLE\r\n");
                try writeTagged(transport, tag, .ok, null, "CAPABILITY completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.noop)) {
                if (session.selected) |mailbox| {
                    try transport.print("* {d} EXISTS\r\n", .{mailbox.messages.items.len});
                }
                try writeTagged(transport, tag, .ok, null, "NOOP completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.logout)) {
                try transport.writeAll("* BYE logging out\r\n");
                session.state = .logout;
                try writeTagged(transport, tag, .ok, null, "LOGOUT completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.namespace)) {
                try transport.writeAll("* NAMESPACE ((\"\" \"/\")) NIL NIL\r\n");
                try writeTagged(transport, tag, .ok, null, "NAMESPACE completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.id)) {
                try transport.writeAll("* ID NIL\r\n");
                try writeTagged(transport, tag, .ok, null, "ID completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.enable)) {
                try writeTagged(transport, tag, .ok, null, "ENABLE completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.login)) {
                if (args.len < 2) {
                    try writeTagged(transport, tag, .bad, null, "LOGIN requires username and password");
                    continue;
                }
                const user = self.store.authenticate(args[0].value, args[1].value) catch {
                    try writeTagged(transport, tag, .no, null, "invalid credentials");
                    continue;
                };
                session.user = user;
                session.state = .authenticated;
                try writeTagged(transport, tag, .ok, null, "LOGIN completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.list)) {
                if (session.user == null) {
                    try writeTagged(transport, tag, .bad, null, "not authenticated");
                    continue;
                }
                if (args.len < 2) {
                    try writeTagged(transport, tag, .bad, null, "LIST requires reference and pattern");
                    continue;
                }
                try self.handleList(transport, session.user.?, args[0].value, args[1].value);
                try writeTagged(transport, tag, .ok, null, "LIST completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.lsub)) {
                if (session.user == null) {
                    try writeTagged(transport, tag, .bad, null, "not authenticated");
                    continue;
                }
                if (args.len < 2) {
                    try writeTagged(transport, tag, .bad, null, "LSUB requires reference and pattern");
                    continue;
                }
                try self.handleLsub(transport, session.user.?, args[0].value, args[1].value);
                try writeTagged(transport, tag, .ok, null, "LSUB completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.create)) {
                if (session.user == null or args.len < 1) {
                    try writeTagged(transport, tag, .bad, null, "CREATE requires mailbox");
                    continue;
                }
                session.user.?.createMailbox(args[0].value, &self.store.next_uid_validity) catch {
                    try writeTagged(transport, tag, .no, null, "mailbox already exists");
                    continue;
                };
                try writeTagged(transport, tag, .ok, null, "CREATE completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.delete)) {
                if (session.user == null or args.len < 1) {
                    try writeTagged(transport, tag, .bad, null, "DELETE requires mailbox");
                    continue;
                }
                session.user.?.deleteMailbox(args[0].value) catch {
                    try writeTagged(transport, tag, .no, null, "cannot delete mailbox");
                    continue;
                };
                try writeTagged(transport, tag, .ok, null, "DELETE completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.rename)) {
                if (session.user == null or args.len < 2) {
                    try writeTagged(transport, tag, .bad, null, "RENAME requires source and destination");
                    continue;
                }
                session.user.?.renameMailbox(args[0].value, args[1].value) catch {
                    try writeTagged(transport, tag, .no, null, "rename failed");
                    continue;
                };
                try writeTagged(transport, tag, .ok, null, "RENAME completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.subscribe) or std.ascii.eqlIgnoreCase(command_name, imap.commands.unsubscribe)) {
                if (session.user == null or args.len < 1) {
                    try writeTagged(transport, tag, .bad, null, "mailbox required");
                    continue;
                }
                const mailbox = session.user.?.getMailbox(args[0].value) orelse {
                    try writeTagged(transport, tag, .no, null, "no such mailbox");
                    continue;
                };
                mailbox.subscribed = std.ascii.eqlIgnoreCase(command_name, imap.commands.subscribe);
                try writeTagged(transport, tag, .ok, null, "subscription updated");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.select) or std.ascii.eqlIgnoreCase(command_name, imap.commands.examine)) {
                if (session.user == null or args.len < 1) {
                    try writeTagged(transport, tag, .bad, null, "SELECT requires mailbox");
                    continue;
                }
                const mailbox = session.user.?.getMailbox(args[0].value) orelse {
                    try writeTagged(transport, tag, .no, null, "no such mailbox");
                    continue;
                };
                session.selected = mailbox;
                session.state = .selected;
                session.read_only = std.ascii.eqlIgnoreCase(command_name, imap.commands.examine);
                try self.writeSelectData(transport, mailbox, session.read_only);
                try writeTagged(
                    transport,
                    tag,
                    .ok,
                    if (session.read_only) "READ-ONLY" else "READ-WRITE",
                    if (session.read_only) "EXAMINE completed" else "SELECT completed",
                );
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.status)) {
                if (session.user == null or args.len < 2) {
                    try writeTagged(transport, tag, .bad, null, "STATUS requires mailbox and items");
                    continue;
                }
                const mailbox = session.user.?.getMailbox(args[0].value) orelse {
                    try writeTagged(transport, tag, .no, null, "no such mailbox");
                    continue;
                };
                try self.writeStatusData(transport, mailbox, args[1].value);
                try writeTagged(transport, tag, .ok, null, "STATUS completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.append)) {
                if (session.user == null or args.len < 2) {
                    try writeTagged(transport, tag, .bad, null, "APPEND requires mailbox and literal");
                    continue;
                }
                const mailbox = session.user.?.getMailbox(args[0].value) orelse {
                    try writeTagged(transport, tag, .no, null, "no such mailbox");
                    continue;
                };
                const literal_token = args[args.len - 1].value;
                const literal_len = parseLiteralMarker(literal_token) catch {
                    try writeTagged(transport, tag, .bad, null, "APPEND requires literal");
                    continue;
                };
                var append_flags = std.ArrayList([]const u8).empty;
                defer freeOwnedStrings(self.allocator, &append_flags);
                if (args.len >= 3 and tokensHaveList(args[1])) {
                    try parseFlagList(self.allocator, args[1].value, &append_flags);
                }
                try transport.writeAll("+ Ready for literal data\r\n");
                const bytes = try reader.readExactAlloc(literal_len);
                defer self.allocator.free(bytes);
                try reader.readCrlf();
                const uid = try mailbox.appendMessage(bytes, append_flags.items, null);
                const code = try std.fmt.allocPrint(self.allocator, "APPENDUID {d} {d}", .{ mailbox.uid_validity, uid });
                defer self.allocator.free(code);
                try writeTagged(transport, tag, .ok, code, "APPEND completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.unselect)) {
                session.selected = null;
                if (session.user != null) session.state = .authenticated;
                session.read_only = false;
                try writeTagged(transport, tag, .ok, null, "UNSELECT completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.idle)) {
                if (session.user == null) {
                    try writeTagged(transport, tag, .bad, null, "not authenticated");
                    continue;
                }
                try transport.writeAll("+ idling\r\n");
                if (session.selected) |mailbox| {
                    try transport.print("* {d} EXISTS\r\n", .{mailbox.messages.items.len});
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
                try writeTagged(transport, tag, .ok, null, "IDLE completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.close)) {
                if (session.selected) |mailbox| {
                    _ = try expungeMailbox(transport, mailbox, true);
                }
                session.selected = null;
                if (session.user != null) session.state = .authenticated;
                session.read_only = false;
                try writeTagged(transport, tag, .ok, null, "CLOSE completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.search)) {
                if (session.selected == null or args.len == 0) {
                    try writeTagged(transport, tag, .bad, null, "SEARCH requires selected mailbox and criteria");
                    continue;
                }
                var criteria = try parseSearchCriteria(self.allocator, args);
                defer freeSearchCriteria(self.allocator, &criteria);
                try self.writeSearchResults(transport, session.selected.?, uid_mode, criteria);
                try writeTagged(transport, tag, .ok, null, "SEARCH completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.fetch)) {
                if (session.selected == null or args.len < 2) {
                    try writeTagged(transport, tag, .bad, null, "FETCH requires message set and items");
                    continue;
                }
                var set = imap.NumSet.parse(self.allocator, if (uid_mode) .uid else .seq, args[0].value) catch {
                    try writeTagged(transport, tag, .bad, null, "invalid message set");
                    continue;
                };
                defer set.deinit();
                try self.writeFetchResults(transport, session.selected.?, uid_mode, &set, args[1].value);
                try writeTagged(transport, tag, .ok, null, "FETCH completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.store)) {
                if (session.selected == null or session.read_only or args.len < 3) {
                    try writeTagged(transport, tag, .bad, null, "STORE requires selected writable mailbox");
                    continue;
                }
                var set = imap.NumSet.parse(self.allocator, if (uid_mode) .uid else .seq, args[0].value) catch {
                    try writeTagged(transport, tag, .bad, null, "invalid message set");
                    continue;
                };
                defer set.deinit();

                const op = args[1].value;
                const action = if (std.mem.startsWith(u8, op, "+")) imap.StoreAction.add else if (std.mem.startsWith(u8, op, "-")) imap.StoreAction.remove else imap.StoreAction.replace;
                const silent = std.mem.indexOf(u8, op, ".SILENT") != null;
                var flags = std.ArrayList([]const u8).empty;
                defer freeOwnedStrings(self.allocator, &flags);
                try parseFlagList(self.allocator, args[2].value, &flags);
                try self.applyStore(transport, session.selected.?, uid_mode, &set, action, silent, flags.items);
                try writeTagged(transport, tag, .ok, null, "STORE completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.copy) or std.ascii.eqlIgnoreCase(command_name, imap.commands.move)) {
                if (session.selected == null or args.len < 2 or session.user == null) {
                    try writeTagged(transport, tag, .bad, null, "COPY/MOVE requires selected mailbox and destination");
                    continue;
                }
                var set = imap.NumSet.parse(self.allocator, if (uid_mode) .uid else .seq, args[0].value) catch {
                    try writeTagged(transport, tag, .bad, null, "invalid message set");
                    continue;
                };
                defer set.deinit();

                const dest = session.user.?.getMailbox(args[1].value) orelse {
                    try writeTagged(transport, tag, .no, null, "destination mailbox not found");
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
                    _ = try expungeMailbox(transport, session.selected.?, false);
                }
                try writeTagged(transport, tag, .ok, code, if (std.ascii.eqlIgnoreCase(command_name, imap.commands.move)) "MOVE completed" else "COPY completed");
                continue;
            }

            if (std.ascii.eqlIgnoreCase(command_name, imap.commands.expunge)) {
                if (session.selected == null or session.read_only) {
                    try writeTagged(transport, tag, .bad, null, "EXPUNGE requires selected writable mailbox");
                    continue;
                }
                _ = try expungeMailbox(transport, session.selected.?, false);
                try writeTagged(transport, tag, .ok, null, "EXPUNGE completed");
                continue;
            }

            try writeTagged(transport, tag, .bad, null, "unsupported command");
        }
    }

    pub fn serveStream(self: *Server, stream: *std.net.Stream) !void {
        try self.serveTransport(wire.Transport.fromNetStream(stream));
    }

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

        const joined = try joinU32s(self.allocator, matches.items);
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
};

pub const Placeholder = Server;

const SessionState = struct {
    state: imap.ConnState = .not_authenticated,
    user: ?*memstore.User = null,
    selected: ?*memstore.Mailbox = null,
    read_only: bool = false,
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
    return true;
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
    return joinU32s(allocator, converted);
}

fn joinU32s(allocator: std.mem.Allocator, values: []const u32) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (values, 0..) |value, index| {
        if (index != 0) try out.append(allocator, ',');
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
