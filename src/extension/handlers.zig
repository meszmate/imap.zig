//! Extension command handlers for IMAP extensions.
//! Each handler function has the signature fn(*CommandContext) anyerror!void
//! and can be registered with the server Dispatcher via ServerExtension.

const std = @import("std");
const dispatch = @import("../server/dispatch.zig");
const server_ext = @import("../server/extensions.zig");

const CommandContext = dispatch.CommandContext;
const ServerExtension = server_ext.ServerExtension;

// ---- ACL Extension (RFC 4314) ----

pub const acl_extension = ServerExtension{
    .name = "ACL",
    .capabilities = &.{"ACL"},
    .handlers = &.{
        .{ .name = "GETACL", .handler = handleGetAcl },
        .{ .name = "SETACL", .handler = handleSetAcl },
        .{ .name = "DELETEACL", .handler = handleDeleteAcl },
        .{ .name = "LISTRIGHTS", .handler = handleListRights },
        .{ .name = "MYRIGHTS", .handler = handleMyRights },
    },
};

fn handleGetAcl(ctx: *CommandContext) anyerror!void {
    if (ctx.args.len < 1) {
        try ctx.transport.print("{s} BAD GETACL requires mailbox\r\n", .{ctx.tag});
        return;
    }
    try ctx.transport.print("{s} OK GETACL completed\r\n", .{ctx.tag});
}

fn handleSetAcl(ctx: *CommandContext) anyerror!void {
    if (ctx.args.len < 3) {
        try ctx.transport.print("{s} BAD SETACL requires mailbox, identifier, rights\r\n", .{ctx.tag});
        return;
    }
    try ctx.transport.print("{s} OK SETACL completed\r\n", .{ctx.tag});
}

fn handleDeleteAcl(ctx: *CommandContext) anyerror!void {
    if (ctx.args.len < 2) {
        try ctx.transport.print("{s} BAD DELETEACL requires mailbox and identifier\r\n", .{ctx.tag});
        return;
    }
    try ctx.transport.print("{s} OK DELETEACL completed\r\n", .{ctx.tag});
}

fn handleListRights(ctx: *CommandContext) anyerror!void {
    if (ctx.args.len < 2) {
        try ctx.transport.print("{s} BAD LISTRIGHTS requires mailbox and identifier\r\n", .{ctx.tag});
        return;
    }
    try ctx.transport.print("* LISTRIGHTS {s} {s} \"\" l r s w i p k x t e a\r\n", .{ ctx.args[0].value, ctx.args[1].value });
    try ctx.transport.print("{s} OK LISTRIGHTS completed\r\n", .{ctx.tag});
}

fn handleMyRights(ctx: *CommandContext) anyerror!void {
    if (ctx.args.len < 1) {
        try ctx.transport.print("{s} BAD MYRIGHTS requires mailbox\r\n", .{ctx.tag});
        return;
    }
    try ctx.transport.print("* MYRIGHTS {s} lrswipdkxtea\r\n", .{ctx.args[0].value});
    try ctx.transport.print("{s} OK MYRIGHTS completed\r\n", .{ctx.tag});
}

// ---- QUOTA Extension (RFC 9208) ----

pub const quota_extension = ServerExtension{
    .name = "QUOTA",
    .capabilities = &.{ "QUOTA", "QUOTA=RES-STORAGE", "QUOTA=RES-MESSAGE" },
    .handlers = &.{
        .{ .name = "GETQUOTA", .handler = handleGetQuota },
        .{ .name = "SETQUOTA", .handler = handleSetQuota },
        .{ .name = "GETQUOTAROOT", .handler = handleGetQuotaRoot },
    },
};

fn handleGetQuota(ctx: *CommandContext) anyerror!void {
    if (ctx.args.len < 1) {
        try ctx.transport.print("{s} BAD GETQUOTA requires root\r\n", .{ctx.tag});
        return;
    }
    try ctx.transport.print("{s} OK GETQUOTA completed\r\n", .{ctx.tag});
}

fn handleSetQuota(ctx: *CommandContext) anyerror!void {
    try ctx.transport.print("{s} OK SETQUOTA completed\r\n", .{ctx.tag});
}

fn handleGetQuotaRoot(ctx: *CommandContext) anyerror!void {
    if (ctx.args.len < 1) {
        try ctx.transport.print("{s} BAD GETQUOTAROOT requires mailbox\r\n", .{ctx.tag});
        return;
    }
    try ctx.transport.print("{s} OK GETQUOTAROOT completed\r\n", .{ctx.tag});
}

// ---- METADATA Extension (RFC 5464) ----

pub const metadata_extension = ServerExtension{
    .name = "METADATA",
    .capabilities = &.{ "METADATA", "METADATA-SERVER" },
    .handlers = &.{
        .{ .name = "GETMETADATA", .handler = handleGetMetadata },
        .{ .name = "SETMETADATA", .handler = handleSetMetadata },
    },
};

fn handleGetMetadata(ctx: *CommandContext) anyerror!void {
    if (ctx.args.len < 1) {
        try ctx.transport.print("{s} BAD GETMETADATA requires mailbox\r\n", .{ctx.tag});
        return;
    }
    try ctx.transport.print("{s} OK GETMETADATA completed\r\n", .{ctx.tag});
}

fn handleSetMetadata(ctx: *CommandContext) anyerror!void {
    if (ctx.args.len < 2) {
        try ctx.transport.print("{s} BAD SETMETADATA requires mailbox and entries\r\n", .{ctx.tag});
        return;
    }
    try ctx.transport.print("{s} OK SETMETADATA completed\r\n", .{ctx.tag});
}

// ---- MOVE Extension (RFC 6851) ----

pub const move_extension = ServerExtension{
    .name = "MOVE",
    .capabilities = &.{"MOVE"},
    .handlers = &.{
        .{ .name = "MOVE", .handler = handleMove },
    },
};

fn handleMove(ctx: *CommandContext) anyerror!void {
    if (ctx.args.len < 2) {
        try ctx.transport.print("{s} BAD MOVE requires sequence set and destination\r\n", .{ctx.tag});
        return;
    }
    try ctx.transport.print("{s} OK MOVE completed\r\n", .{ctx.tag});
}

// ---- SORT Extension (RFC 5256) ----

pub const sort_extension = ServerExtension{
    .name = "SORT",
    .capabilities = &.{"SORT"},
    .handlers = &.{
        .{ .name = "SORT", .handler = handleSort },
    },
};

fn handleSort(ctx: *CommandContext) anyerror!void {
    if (ctx.args.len < 2) {
        try ctx.transport.print("{s} BAD SORT requires criteria and charset\r\n", .{ctx.tag});
        return;
    }
    try ctx.transport.print("{s} OK SORT completed\r\n", .{ctx.tag});
}

// ---- THREAD Extension (RFC 5256) ----

pub const thread_extension = ServerExtension{
    .name = "THREAD",
    .capabilities = &.{ "THREAD=REFERENCES", "THREAD=ORDEREDSUBJECT" },
    .handlers = &.{
        .{ .name = "THREAD", .handler = handleThread },
    },
};

fn handleThread(ctx: *CommandContext) anyerror!void {
    if (ctx.args.len < 2) {
        try ctx.transport.print("{s} BAD THREAD requires algorithm and charset\r\n", .{ctx.tag});
        return;
    }
    try ctx.transport.print("{s} OK THREAD completed\r\n", .{ctx.tag});
}

// ---- NAMESPACE Extension (RFC 2342) ----

pub const namespace_extension = ServerExtension{
    .name = "NAMESPACE",
    .capabilities = &.{"NAMESPACE"},
    .handlers = &.{
        .{ .name = "NAMESPACE", .handler = handleNamespace },
    },
};

fn handleNamespace(ctx: *CommandContext) anyerror!void {
    try ctx.transport.writeAll("* NAMESPACE ((\"\" \"/\")) NIL NIL\r\n");
    try ctx.transport.print("{s} OK NAMESPACE completed\r\n", .{ctx.tag});
}

// ---- ID Extension (RFC 2971) ----

pub const id_extension = ServerExtension{
    .name = "ID",
    .capabilities = &.{"ID"},
    .handlers = &.{
        .{ .name = "ID", .handler = handleId },
    },
};

fn handleId(ctx: *CommandContext) anyerror!void {
    try ctx.transport.writeAll("* ID (\"name\" \"imap.zig\")\r\n");
    try ctx.transport.print("{s} OK ID completed\r\n", .{ctx.tag});
}

// ---- ENABLE Extension (RFC 5161) ----

pub const enable_extension = ServerExtension{
    .name = "ENABLE",
    .capabilities = &.{"ENABLE"},
    .handlers = &.{
        .{ .name = "ENABLE", .handler = handleEnable },
    },
};

fn handleEnable(ctx: *CommandContext) anyerror!void {
    try ctx.transport.writeAll("* ENABLED");
    for (ctx.args) |arg| {
        try ctx.transport.print(" {s}", .{arg.value});
    }
    try ctx.transport.writeAll("\r\n");
    try ctx.transport.print("{s} OK ENABLE completed\r\n", .{ctx.tag});
}

// ---- IDLE Extension (RFC 2177) ----

pub const idle_extension = ServerExtension{
    .name = "IDLE",
    .capabilities = &.{"IDLE"},
    .handlers = &.{
        .{ .name = "IDLE", .handler = handleIdle },
    },
};

fn handleIdle(ctx: *CommandContext) anyerror!void {
    try ctx.transport.writeAll("+ idling\r\n");
    try ctx.transport.print("{s} OK IDLE completed\r\n", .{ctx.tag});
}

// ---- COMPRESS Extension (RFC 4978) ----

pub const compress_extension = ServerExtension{
    .name = "COMPRESS",
    .capabilities = &.{"COMPRESS=DEFLATE"},
    .handlers = &.{
        .{ .name = "COMPRESS", .handler = handleCompress },
    },
};

fn handleCompress(ctx: *CommandContext) anyerror!void {
    try ctx.transport.print("{s} OK COMPRESS completed\r\n", .{ctx.tag});
}

// ---- UNAUTHENTICATE Extension ----

pub const unauthenticate_extension = ServerExtension{
    .name = "UNAUTHENTICATE",
    .capabilities = &.{"UNAUTHENTICATE"},
    .handlers = &.{
        .{ .name = "UNAUTHENTICATE", .handler = handleUnauthenticate },
    },
};

fn handleUnauthenticate(ctx: *CommandContext) anyerror!void {
    ctx.session.state = .not_authenticated;
    try ctx.transport.print("{s} OK UNAUTHENTICATE completed\r\n", .{ctx.tag});
}

// ---- REPLACE Extension (RFC 8508) ----

pub const replace_extension = ServerExtension{
    .name = "REPLACE",
    .capabilities = &.{"REPLACE"},
    .handlers = &.{
        .{ .name = "REPLACE", .handler = handleReplace },
    },
};

fn handleReplace(ctx: *CommandContext) anyerror!void {
    if (ctx.args.len < 2) {
        try ctx.transport.print("{s} BAD REPLACE requires message set and mailbox\r\n", .{ctx.tag});
        return;
    }
    try ctx.transport.print("{s} OK REPLACE completed\r\n", .{ctx.tag});
}

// ---- STARTTLS Extension ----
// Note: Actual TLS upgrade is handled by the Server.serveConnection loop,
// which swaps the transport after sending OK. This extension handler is
// used by the Dispatcher/ExtensionManager path and sends the OK response;
// the calling code is responsible for performing the actual TLS handshake.

pub const starttls_extension = ServerExtension{
    .name = "STARTTLS",
    .capabilities = &.{"STARTTLS"},
    .handlers = &.{
        .{ .name = "STARTTLS", .handler = handleStartTls },
    },
};

fn handleStartTls(ctx: *CommandContext) anyerror!void {
    if (ctx.session.is_tls) {
        try ctx.transport.print("{s} BAD already using TLS\r\n", .{ctx.tag});
        return;
    }
    try ctx.transport.print("{s} OK Begin TLS negotiation now\r\n", .{ctx.tag});
    ctx.session.is_tls = true;
}

// ---- UNSELECT Extension (RFC 3691) ----

pub const unselect_extension = ServerExtension{
    .name = "UNSELECT",
    .capabilities = &.{"UNSELECT"},
    .handlers = &.{
        .{ .name = "UNSELECT", .handler = handleUnselect },
    },
};

fn handleUnselect(ctx: *CommandContext) anyerror!void {
    ctx.session.unselect();
    try ctx.transport.print("{s} OK UNSELECT completed\r\n", .{ctx.tag});
}

// ---- UIDPLUS Extension (RFC 4315) ----

pub const uidplus_extension = ServerExtension{
    .name = "UIDPLUS",
    .capabilities = &.{"UIDPLUS"},
};

// ---- SASL-IR Extension (RFC 4959) ----

pub const sasl_ir_extension = ServerExtension{
    .name = "SASL-IR",
    .capabilities = &.{"SASL-IR"},
};

// ---- LITERAL+ Extension (RFC 7888) ----

pub const literal_plus_extension = ServerExtension{
    .name = "LITERAL+",
    .capabilities = &.{"LITERAL+"},
};

// ---- SPECIAL-USE Extension (RFC 6154) ----

pub const special_use_extension = ServerExtension{
    .name = "SPECIAL-USE",
    .capabilities = &.{ "SPECIAL-USE", "CREATE-SPECIAL-USE" },
};

// ---- CONDSTORE Extension (RFC 7162) ----

pub const condstore_extension = ServerExtension{
    .name = "CONDSTORE",
    .capabilities = &.{"CONDSTORE"},
};

// ---- QRESYNC Extension (RFC 7162) ----

pub const qresync_extension = ServerExtension{
    .name = "QRESYNC",
    .capabilities = &.{"QRESYNC"},
};

// ---- ESEARCH Extension (RFC 4731) ----

pub const esearch_extension = ServerExtension{
    .name = "ESEARCH",
    .capabilities = &.{"ESEARCH"},
};

// ---- LIST-EXTENDED Extension (RFC 5258) ----

pub const list_extended_extension = ServerExtension{
    .name = "LIST-EXTENDED",
    .capabilities = &.{"LIST-EXTENDED"},
};

// ---- LIST-STATUS Extension (RFC 5819) ----

pub const list_status_extension = ServerExtension{
    .name = "LIST-STATUS",
    .capabilities = &.{"LIST-STATUS"},
};

// ---- CHILDREN Extension (RFC 3348) ----

pub const children_extension = ServerExtension{
    .name = "CHILDREN",
    .capabilities = &.{"CHILDREN"},
};

// ---- BINARY Extension (RFC 3516) ----

pub const binary_extension = ServerExtension{
    .name = "BINARY",
    .capabilities = &.{"BINARY"},
};

// ---- MULTIAPPEND Extension (RFC 3502) ----

pub const multiappend_extension = ServerExtension{
    .name = "MULTIAPPEND",
    .capabilities = &.{"MULTIAPPEND"},
};

// ---- OBJECTID Extension (RFC 8474) ----

pub const objectid_extension = ServerExtension{
    .name = "OBJECTID",
    .capabilities = &.{"OBJECTID"},
};

// ---- PREVIEW Extension (RFC 8970) ----

pub const preview_extension = ServerExtension{
    .name = "PREVIEW",
    .capabilities = &.{"PREVIEW"},
};

// ---- SAVEDATE Extension (RFC 8514) ----

pub const savedate_extension = ServerExtension{
    .name = "SAVEDATE",
    .capabilities = &.{"SAVEDATE"},
};

// ---- STATUS=SIZE Extension (RFC 8438) ----

pub const status_size_extension = ServerExtension{
    .name = "STATUS=SIZE",
    .capabilities = &.{"STATUS=SIZE"},
};

// ---- APPENDLIMIT Extension (RFC 7889) ----

pub const appendlimit_extension = ServerExtension{
    .name = "APPENDLIMIT",
    .capabilities = &.{"APPENDLIMIT"},
};

// ---- UTF8=ACCEPT Extension (RFC 6855) ----

pub const utf8_accept_extension = ServerExtension{
    .name = "UTF8=ACCEPT",
    .capabilities = &.{"UTF8=ACCEPT"},
};

// ---- WITHIN Extension (RFC 5032) ----

pub const within_extension = ServerExtension{
    .name = "WITHIN",
    .capabilities = &.{"WITHIN"},
};

// ---- SEARCHRES Extension (RFC 5182) ----

pub const searchres_extension = ServerExtension{
    .name = "SEARCHRES",
    .capabilities = &.{"SEARCHRES"},
};

// ---- SEARCH=FUZZY Extension (RFC 6203) ----

pub const search_fuzzy_extension = ServerExtension{
    .name = "SEARCH=FUZZY",
    .capabilities = &.{"SEARCH=FUZZY"},
};

/// Returns all built-in extension definitions with their handlers.
pub fn allExtensions() []const ServerExtension {
    return &.{
        acl_extension,
        quota_extension,
        metadata_extension,
        move_extension,
        sort_extension,
        thread_extension,
        namespace_extension,
        id_extension,
        enable_extension,
        idle_extension,
        compress_extension,
        unauthenticate_extension,
        replace_extension,
        starttls_extension,
        unselect_extension,
        uidplus_extension,
        sasl_ir_extension,
        literal_plus_extension,
        special_use_extension,
        condstore_extension,
        qresync_extension,
        esearch_extension,
        list_extended_extension,
        list_status_extension,
        children_extension,
        binary_extension,
        multiappend_extension,
        objectid_extension,
        preview_extension,
        savedate_extension,
        status_size_extension,
        appendlimit_extension,
        utf8_accept_extension,
        within_extension,
        searchres_extension,
        search_fuzzy_extension,
    };
}
