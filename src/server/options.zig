const std = @import("std");
const wire = @import("../wire/root.zig");

/// Callback that upgrades a plain transport to TLS and returns the new transport.
/// The callback receives an opaque context pointer and the underlying TCP stream.
/// It must perform the TLS handshake and return a Transport wrapping the TLS connection.
pub const TlsUpgradeFn = *const fn (ctx: *anyopaque, stream: std.net.Stream) anyerror!wire.Transport;

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

    /// Allow LOGIN/AUTHENTICATE commands without TLS.
    /// When false and STARTTLS is enabled, auth commands are rejected
    /// until TLS is negotiated.
    allow_insecure_auth: bool = false,

    /// Enable STARTTLS command. Requires tls_upgrade_fn to be set.
    enable_starttls: bool = false,

    /// Callback to upgrade a plain connection to TLS.
    /// Called after the server sends "OK Begin TLS negotiation now".
    tls_upgrade_fn: ?TlsUpgradeFn = null,

    /// Opaque context passed to tls_upgrade_fn.
    tls_upgrade_ctx: ?*anyopaque = null,

    /// Custom capabilities to advertise (null = use defaults)
    capabilities: ?[]const []const u8 = null,

    pub fn defaultCapabilities() []const u8 {
        return "IMAP4rev1 UIDPLUS MOVE NAMESPACE ID UNSELECT IDLE ENABLE SASL-IR AUTH=PLAIN AUTH=LOGIN AUTH=EXTERNAL AUTH=CRAM-MD5 AUTH=XOAUTH2 AUTH=OAUTHBEARER AUTH=ANONYMOUS SORT THREAD=REFERENCES THREAD=ORDEREDSUBJECT ACL QUOTA METADATA COMPRESS=DEFLATE UNAUTHENTICATE REPLACE";
    }

    pub fn starttlsCapabilities() []const u8 {
        return "IMAP4rev1 UIDPLUS MOVE NAMESPACE ID UNSELECT IDLE ENABLE SASL-IR AUTH=PLAIN AUTH=LOGIN AUTH=EXTERNAL AUTH=CRAM-MD5 AUTH=XOAUTH2 AUTH=OAUTHBEARER AUTH=ANONYMOUS SORT THREAD=REFERENCES THREAD=ORDEREDSUBJECT ACL QUOTA METADATA STARTTLS COMPRESS=DEFLATE UNAUTHENTICATE REPLACE";
    }

    pub fn logindisabledCapabilities() []const u8 {
        return "IMAP4rev1 UIDPLUS MOVE NAMESPACE ID UNSELECT IDLE ENABLE SASL-IR SORT THREAD=REFERENCES THREAD=ORDEREDSUBJECT ACL QUOTA METADATA STARTTLS COMPRESS=DEFLATE UNAUTHENTICATE REPLACE LOGINDISABLED";
    }
};
