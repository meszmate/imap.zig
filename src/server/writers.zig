const std = @import("std");
const imap = @import("../root.zig");
const wire = @import("../wire/root.zig");

/// FetchWriter writes FETCH response data for a single message
pub const FetchWriter = struct {
    allocator: std.mem.Allocator,
    transport: wire.Transport,
    uid_only: bool = false,

    pub fn init(allocator: std.mem.Allocator, transport: wire.Transport) FetchWriter {
        return .{ .allocator = allocator, .transport = transport };
    }

    pub fn writeFlags(self: *FetchWriter, seq_num: u32, message_flags: []const []const u8) !void {
        try self.transport.print("* {d} FETCH (FLAGS (", .{seq_num});
        for (message_flags, 0..) |flag, index| {
            if (index != 0) try self.transport.writeAll(" ");
            try self.transport.writeAll(flag);
        }
        try self.transport.writeAll("))\r\n");
    }

    pub fn writeFetchData(self: *FetchWriter, data: *const imap.FetchMessageData) !void {
        if (self.uid_only) {
            try self.transport.print("* {d} UIDFETCH (", .{data.uid orelse 0});
        } else {
            try self.transport.print("* {d} FETCH (", .{data.seq});
        }
        var first = true;

        if (data.uid) |uid| {
            if (first) {} else try self.transport.writeAll(" ");
            first = false;
            try self.transport.print("UID {d}", .{uid});
        }

        if (data.flags.len > 0 or !first) {
            if (!first) try self.transport.writeAll(" ");
            first = false;
            try self.transport.writeAll("FLAGS (");
            for (data.flags, 0..) |flag, index| {
                if (index != 0) try self.transport.writeAll(" ");
                try self.transport.writeAll(flag);
            }
            try self.transport.writeAll(")");
        }

        if (data.internal_date) |date| {
            if (!first) try self.transport.writeAll(" ");
            first = false;
            try self.transport.print("INTERNALDATE \"{s}\"", .{date});
        }

        if (data.rfc822_size) |size| {
            if (!first) try self.transport.writeAll(" ");
            first = false;
            try self.transport.print("RFC822.SIZE {d}", .{size});
        }

        if (data.mod_seq) |mod_seq| {
            if (!first) try self.transport.writeAll(" ");
            first = false;
            try self.transport.print("MODSEQ ({d})", .{mod_seq});
        }

        if (data.preview) |preview| {
            if (!first) try self.transport.writeAll(" ");
            first = false;
            try self.transport.print("PREVIEW \"{s}\"", .{preview});
        }

        if (data.email_id) |email_id| {
            if (!first) try self.transport.writeAll(" ");
            first = false;
            try self.transport.print("EMAILID ({s})", .{email_id});
        }

        if (data.thread_id) |thread_id| {
            if (!first) try self.transport.writeAll(" ");
            first = false;
            try self.transport.print("THREADID ({s})", .{thread_id});
        }

        for (data.body_sections) |section| {
            if (!first) try self.transport.writeAll(" ");
            first = false;
            try self.transport.print("BODY[{s}] {{{d}}}\r\n", .{ section.label, section.bytes.len });
            try self.transport.writeAll(section.bytes);
        }

        try self.transport.writeAll(")\r\n");
    }
};

/// ListWriter writes LIST response data
pub const ListWriter = struct {
    allocator: std.mem.Allocator,
    transport: wire.Transport,

    pub fn init(allocator: std.mem.Allocator, transport: wire.Transport) ListWriter {
        return .{ .allocator = allocator, .transport = transport };
    }

    pub fn writeList(self: *ListWriter, data: *const imap.ListData) !void {
        try self.transport.writeAll("* LIST (");
        for (data.attrs, 0..) |attr, index| {
            if (index != 0) try self.transport.writeAll(" ");
            try self.transport.writeAll(attr);
        }
        if (data.delimiter) |delim| {
            try self.transport.print(") \"{c}\" ", .{delim});
        } else {
            try self.transport.writeAll(") NIL ");
        }
        try self.transport.print("\"{s}\"\r\n", .{data.mailbox});
    }
};

/// UpdateWriter writes unsolicited server updates (for IDLE/Poll)
pub const UpdateWriter = struct {
    allocator: std.mem.Allocator,
    transport: wire.Transport,

    pub fn init(allocator: std.mem.Allocator, transport: wire.Transport) UpdateWriter {
        return .{ .allocator = allocator, .transport = transport };
    }

    pub fn writeExists(self: *UpdateWriter, num: u32) !void {
        try self.transport.print("* {d} EXISTS\r\n", .{num});
    }

    pub fn writeExpunge(self: *UpdateWriter, seq_num: u32) !void {
        try self.transport.print("* {d} EXPUNGE\r\n", .{seq_num});
    }

    pub fn writeRecent(self: *UpdateWriter, num: u32) !void {
        try self.transport.print("* {d} RECENT\r\n", .{num});
    }

    pub fn writeMailboxFlags(self: *UpdateWriter, message_flags: []const []const u8) !void {
        try self.transport.writeAll("* FLAGS (");
        for (message_flags, 0..) |flag, index| {
            if (index != 0) try self.transport.writeAll(" ");
            try self.transport.writeAll(flag);
        }
        try self.transport.writeAll(")\r\n");
    }

    pub fn writeMessageFlags(self: *UpdateWriter, seq_num: u32, message_flags: []const []const u8) !void {
        try self.transport.print("* {d} FETCH (FLAGS (", .{seq_num});
        for (message_flags, 0..) |flag, index| {
            if (index != 0) try self.transport.writeAll(" ");
            try self.transport.writeAll(flag);
        }
        try self.transport.writeAll("))\r\n");
    }
};

/// ExpungeWriter writes EXPUNGE responses
pub const ExpungeWriter = struct {
    allocator: std.mem.Allocator,
    transport: wire.Transport,
    uid_only: bool = false,

    pub fn init(allocator: std.mem.Allocator, transport: wire.Transport) ExpungeWriter {
        return .{ .allocator = allocator, .transport = transport };
    }

    pub fn writeExpunge(self: *ExpungeWriter, seq_num: u32) !void {
        if (self.uid_only) {
            try self.transport.print("* VANISHED {d}\r\n", .{seq_num});
        } else {
            try self.transport.print("* {d} EXPUNGE\r\n", .{seq_num});
        }
    }
};

/// MoveWriter combines expunge and copy data writing
pub const MoveWriter = struct {
    expunge: ExpungeWriter,
    transport: wire.Transport,

    pub fn init(allocator: std.mem.Allocator, transport: wire.Transport) MoveWriter {
        return .{
            .expunge = ExpungeWriter.init(allocator, transport),
            .transport = transport,
        };
    }

    pub fn writeExpunge(self: *MoveWriter, seq_num: u32) !void {
        try self.expunge.writeExpunge(seq_num);
    }

    pub fn writeCopyData(self: *MoveWriter, data: *const imap.CopyData) !void {
        if (data.uid_validity) |uid_validity| {
            try self.transport.print("* OK [COPYUID {d}", .{uid_validity});
            // source UIDs
            try self.transport.writeAll(" ");
            for (data.source_uids, 0..) |uid, index| {
                if (index != 0) try self.transport.writeAll(",");
                try self.transport.print("{d}", .{uid});
            }
            try self.transport.writeAll(" ");
            for (data.dest_uids, 0..) |uid, index| {
                if (index != 0) try self.transport.writeAll(",");
                try self.transport.print("{d}", .{uid});
            }
            try self.transport.writeAll("]\r\n");
        }
    }
};
