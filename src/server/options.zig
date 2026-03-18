const std = @import("std");

pub const Options = struct {
    /// Greeting text sent to clients on connect
    greeting_text: []const u8 = "imap.zig ready",

    /// Maximum literal size in bytes (0 = unlimited)
    max_literal_size: u64 = 0,

    /// Read timeout in milliseconds (0 = no timeout)
    read_timeout_ms: u64 = 0,

    /// Write timeout in milliseconds (0 = no timeout)
    write_timeout_ms: u64 = 0,

    /// Idle timeout in milliseconds (default 30 minutes)
    idle_timeout_ms: u64 = 30 * 60 * 1000,

    /// Maximum number of concurrent connections (0 = unlimited)
    max_connections: u32 = 0,

    /// Allow LOGIN command without TLS
    allow_insecure_auth: bool = false,

    /// Enable STARTTLS command
    enable_starttls: bool = false,

    /// Custom capabilities to advertise (null = use defaults)
    capabilities: ?[]const []const u8 = null,

    pub fn defaultCapabilities() []const u8 {
        return "IMAP4rev1 UIDPLUS MOVE NAMESPACE ID UNSELECT IDLE ENABLE SASL-IR AUTH=PLAIN AUTH=LOGIN AUTH=EXTERNAL AUTH=CRAM-MD5 AUTH=XOAUTH2 AUTH=OAUTHBEARER AUTH=ANONYMOUS SORT THREAD=REFERENCES THREAD=ORDEREDSUBJECT ACL QUOTA METADATA STARTTLS COMPRESS=DEFLATE UNAUTHENTICATE REPLACE";
    }
};
