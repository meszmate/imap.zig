const std = @import("std");
const wire = @import("../wire/root.zig");

/// Callback function types for unsolicited server responses.
pub const ExistsHandler = *const fn (num_messages: u32) void;
pub const RecentHandler = *const fn (num_recent: u32) void;
pub const ExpungeHandler = *const fn (seq_num: u32) void;
pub const FetchHandler = *const fn (seq_num: u32, data: []const u8) void;

/// UnilateralDataHandler holds callbacks for unsolicited server responses
/// that arrive outside normal command-response flow (e.g. during IDLE or
/// between commands).
pub const UnilateralDataHandler = struct {
    on_exists: ?ExistsHandler = null,
    on_recent: ?RecentHandler = null,
    on_expunge: ?ExpungeHandler = null,
    on_fetch: ?FetchHandler = null,
};

/// Client configuration options matching Go's client.Options.
pub const Options = struct {
    /// Read timeout in milliseconds (0 = no timeout).
    read_timeout_ms: u64 = 0,

    /// Write timeout in milliseconds (0 = no timeout).
    write_timeout_ms: u64 = 0,

    /// IDLE timeout in milliseconds (default 30 minutes).
    idle_timeout_ms: u64 = 30 * 60 * 1000,

    /// Handler for unsolicited server data.
    unilateral_handler: ?UnilateralDataHandler = null,

    /// Enable debug logging of wire traffic.
    debug_log: bool = false,

    /// TLS configuration for STARTTLS and direct TLS connections.
    tls_options: ?wire.TlsOptions = null,

    pub fn defaultOptions() Options {
        return .{};
    }
};

/// MailboxState tracks the current state of the selected mailbox,
/// updated by both explicit commands and unsolicited server responses.
pub const MailboxState = struct {
    name: ?[]const u8 = null,
    num_messages: u32 = 0,
    num_recent: u32 = 0,
    uid_validity: u32 = 0,
    uid_next: u32 = 0,
    first_unseen: ?u32 = null,
    read_only: bool = false,

    pub fn reset(self: *MailboxState) void {
        self.name = null;
        self.num_messages = 0;
        self.num_recent = 0;
        self.uid_validity = 0;
        self.uid_next = 0;
        self.first_unseen = null;
        self.read_only = false;
    }

    pub fn updateFromLine(self: *MailboxState, line: []const u8, handler: ?UnilateralDataHandler) void {
        if (!std.mem.startsWith(u8, line, "* ")) return;
        const payload = line[2..];

        if (std.mem.endsWith(u8, payload, " EXISTS")) {
            const num = std.fmt.parseInt(u32, payload[0 .. payload.len - " EXISTS".len], 10) catch return;
            self.num_messages = num;
            if (handler) |h| if (h.on_exists) |cb| cb(num);
        } else if (std.mem.endsWith(u8, payload, " RECENT")) {
            const num = std.fmt.parseInt(u32, payload[0 .. payload.len - " RECENT".len], 10) catch return;
            self.num_recent = num;
            if (handler) |h| if (h.on_recent) |cb| cb(num);
        } else if (std.mem.endsWith(u8, payload, " EXPUNGE")) {
            const num = std.fmt.parseInt(u32, payload[0 .. payload.len - " EXPUNGE".len], 10) catch return;
            if (self.num_messages > 0) self.num_messages -= 1;
            if (handler) |h| if (h.on_expunge) |cb| cb(num);
        } else if (std.mem.indexOf(u8, payload, " FETCH ") != null) {
            const space = std.mem.indexOfScalar(u8, payload, ' ') orelse return;
            const seq = std.fmt.parseInt(u32, payload[0..space], 10) catch return;
            if (handler) |h| if (h.on_fetch) |cb| cb(seq, payload);
        }
    }
};
