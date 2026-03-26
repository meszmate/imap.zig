const std = @import("std");
const Transport = @import("transport.zig").Transport;
const tls = std.crypto.tls;
const Certificate = std.crypto.Certificate;

/// TLS configuration for client connections.
pub const TlsOptions = struct {
    /// How to verify the server's hostname.
    host: union(enum) {
        /// Skip hostname verification (insecure, for testing only).
        no_verification,
        /// Verify against an explicit hostname.
        explicit: []const u8,
    } = .no_verification,

    /// How to verify server certificate authenticity.
    ca: union(enum) {
        /// Skip CA verification (insecure, for testing only).
        no_verification,
        /// Accept self-signed certificates.
        self_signed,
        /// Verify against a CA bundle.
        bundle: Certificate.Bundle,
    } = .no_verification,

    /// Allow truncation attacks (not recommended).
    allow_truncation_attacks: bool = false,
};

const buf_size = tls.max_ciphertext_record_len;

/// A TLS-encrypted transport wrapping an underlying TCP stream.
///
/// Uses `std.crypto.tls.Client` for the TLS layer and exposes
/// a `Transport` interface for use with the IMAP client.
///
/// Must be heap-allocated (contains self-referential pointers).
pub const TlsTransport = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,

    // Underlying TCP IO (stable pointers required by TLS client)
    stream_reader: std.net.Stream.Reader,
    stream_writer: std.net.Stream.Writer,

    // TLS client state
    tls_client: tls.Client,

    // Buffers for the underlying stream IO
    stream_read_buf: [buf_size]u8,
    stream_write_buf: [buf_size]u8,

    // Buffers for the TLS client's decrypted reader/writer
    tls_read_buf: [buf_size]u8,
    tls_write_buf: [buf_size]u8,

    /// Perform a TLS handshake over an existing TCP stream and return
    /// a heap-allocated `TlsTransport`.
    pub fn init(allocator: std.mem.Allocator, stream: std.net.Stream, options: TlsOptions) !*TlsTransport {
        const self = try allocator.create(TlsTransport);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.stream = stream;

        // Zero out buffers
        self.stream_read_buf = .{0} ** buf_size;
        self.stream_write_buf = .{0} ** buf_size;
        self.tls_read_buf = .{0} ** buf_size;
        self.tls_write_buf = .{0} ** buf_size;

        // Create stream reader/writer using the stable buffer memory
        self.stream_reader = std.net.Stream.reader(stream, &self.stream_read_buf);
        self.stream_writer = std.net.Stream.writer(stream, &self.stream_write_buf);

        // Perform TLS handshake
        self.tls_client = tls.Client.init(
            self.stream_reader.interface(),
            &self.stream_writer.interface,
            .{
                .host = switch (options.host) {
                    .no_verification => .no_verification,
                    .explicit => |h| .{ .explicit = h },
                },
                .ca = switch (options.ca) {
                    .no_verification => .no_verification,
                    .self_signed => .self_signed,
                    .bundle => |b| .{ .bundle = b },
                },
                .allow_truncation_attacks = options.allow_truncation_attacks,
                .read_buffer = &self.tls_read_buf,
                .write_buffer = &self.tls_write_buf,
            },
        ) catch return error.TlsHandshakeFailed;

        return self;
    }

    /// Return a `Transport` that reads/writes through this TLS connection.
    pub fn transport(self: *TlsTransport) Transport {
        return .{
            .ctx = self,
            .read_fn = tlsRead,
            .write_fn = tlsWrite,
            .close_fn = tlsClose,
        };
    }

    /// Clean up the TLS transport and free heap memory.
    /// Does NOT close the underlying TCP stream.
    pub fn deinit(self: *TlsTransport) void {
        self.allocator.destroy(self);
    }

    /// Clean up and also close the underlying TCP stream.
    pub fn deinitAndClose(self: *TlsTransport) void {
        self.stream.close();
        self.allocator.destroy(self);
    }

    fn tlsRead(ctx: *anyopaque, buffer: []u8) anyerror!usize {
        const self: *TlsTransport = @ptrCast(@alignCast(ctx));
        const n = self.tls_client.reader.readSliceShort(buffer) catch return error.TlsReadFailed;
        return n;
    }

    fn tlsWrite(ctx: *anyopaque, buffer: []const u8) anyerror!usize {
        const self: *TlsTransport = @ptrCast(@alignCast(ctx));
        self.tls_client.writer.writeAll(buffer) catch return error.TlsWriteFailed;
        self.tls_client.writer.flush() catch return error.TlsWriteFailed;
        return buffer.len;
    }

    fn tlsClose(ctx: *anyopaque) anyerror!void {
        const self: *TlsTransport = @ptrCast(@alignCast(ctx));
        self.deinitAndClose();
    }
};
