# imap.zig

[![CI](https://github.com/meszmate/imap.zig/actions/workflows/ci.yml/badge.svg)](https://github.com/meszmate/imap.zig/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

`imap.zig` is a zero-dependency IMAP library for Zig inspired by the shape of `imap-go`, built around a reusable protocol core plus a synchronous client and in-memory server.

It is designed as a practical foundation for both IMAP tooling and embedded mail services:

- IMAP4rev1-oriented protocol types, status parsing, number set parsing, modified UTF-7 mailbox handling, and a broader registry-backed capability surface
- Public wire package with encoder/decoder primitives, literal handling, line reading, transports (plain TCP and TLS via `std.crypto.tls`), and modified UTF-7
- Synchronous client with greeting parsing, tagged command execution, and helpers for `CAPABILITY`, `NOOP`, `LOGIN`, `AUTHENTICATE` (`PLAIN`, `LOGIN`, `EXTERNAL`, `ANONYMOUS`, `CRAM-MD5`, `XOAUTH2`, `OAUTHBEARER`), `SELECT`/`EXAMINE`, `LIST`, `LSUB`, `CREATE`, `DELETE`, `RENAME`, `SUBSCRIBE`, `UNSUBSCRIBE`, `NAMESPACE`, `ID`, `ENABLE`, `STATUS`, `APPEND`, `SEARCH`, `FETCH`, `IDLE`, `SORT`, `THREAD`, `GETACL`, `SETACL`, `DELETEACL`, `LISTRIGHTS`, `MYRIGHTS`, `GETQUOTA`, `SETQUOTA`, `GETQUOTAROOT`, `GETMETADATA`, `SETMETADATA`, `COMPRESS`, `STARTTLS`, `UNAUTHENTICATE`, `REPLACE`, and `LOGOUT`; UID command variants (`uidFetch`, `uidStore`, `uidCopy`, `uidMove`, `uidExpunge`, `uidSearch`, `uidSort`), capability convenience methods (`hasCap`, `supportsIdle`, `supportsMove`, etc.), and TLS support (`connectTls` for implicit TLS, `starttls` for STARTTLS upgrade)
- In-memory server and store with core commands including `CAPABILITY`, `NOOP`, `LOGOUT`, `LOGIN`, `AUTHENTICATE` (`PLAIN`, `LOGIN`, `EXTERNAL`, `ANONYMOUS`, `CRAM-MD5`, `XOAUTH2`, `OAUTHBEARER`), `NAMESPACE`, `ID`, `ENABLE`, `LIST`, `LSUB`, `CREATE`, `DELETE`, `RENAME`, `SUBSCRIBE`, `UNSUBSCRIBE`, `SELECT`, `EXAMINE`, `STATUS`, `APPEND`, `IDLE`, `UNSELECT`, `CLOSE`, `SEARCH`, `FETCH`, `STORE`, `COPY`, `MOVE`, `EXPUNGE`, `SORT`, `THREAD`, `GETACL`, `SETACL`, `DELETEACL`, `LISTRIGHTS`, `MYRIGHTS`, `GETQUOTA`, `SETQUOTA`, `GETQUOTAROOT`, `GETMETADATA`, `SETMETADATA`, `COMPRESS`, `STARTTLS`, `UNAUTHENTICATE`, and `REPLACE`; server Options, Dispatcher, specialized Writers (FetchWriter, ListWriter, UpdateWriter, ExpungeWriter, MoveWriter), and Trackers (MailboxTracker, SessionTracker)
- Auth namespace with mechanism helpers for `ANONYMOUS`, `CRAM-MD5`, `EXTERNAL`, `LOGIN`, `OAUTHBEARER`, `PLAIN`, and `XOAUTH2`
- Filesystem-backed and optional PostgreSQL-backed store backends in addition to the in-memory reference store, with full message CRUD, flag management, UID tracking, subscriptions, and search
- Type-erased store backend/user/mailbox interfaces with full Mailbox operations (info, getMessages, setFlags, copyMessages, expunge, searchMessages, listUids, moveMessages) and ProtocolAdapter for seq/UID bridging
- Explicit connection state machine and extension registry inspired by the local `~/imap-go` architecture
- Public middleware chain primitives plus reusable logging, recovery, timeout, rate-limit, and metrics middleware
- Public server connection/session primitives and a reusable client connection pool
- Extended protocol types: `CreateOptions`, `StoreOptions`, `NamespaceData`, `IMAPError`, `ListReturnMetadata`, `SearchReturnPartial`, `MultiSearchResult`; enhanced `AppendOptions` (binary, utf8), `ListOptions`/`ListData` (extended return options), `SelectOptions` (condstore, qresync), `StatusOptions`/`StatusData` (append_limit, deleted, mailbox_id)
- Test harness (`imaptest` module) with `Harness` and `MockSession` for integration testing
- Transport abstraction for testing, scripting, and custom I/O
- GitHub Actions CI with multi-platform build, test, and cross-compile jobs, plus examples and unit tests

## Status

This repository is a strong first release, not the end of the protocol surface.

Implemented now:

- Core IMAP4rev1 command flow over plain TCP
- Modified UTF-7 encode/decode
- In-memory mailbox store and message flag management
- Filesystem-backed mailbox/user persistence primitives
- Sequence-set and UID-set parsing
- Core command parsing and response generation
- Basic IDLE flow and `DONE` termination
- Capability, mailbox attribute, and response-code coverage widened from the current RFC/IANA registry surface
- Extension registry with a much broader built-in inventory and dependency resolution across the local `~/imap-go` extension families
- Explicit connection state machine for RFC-style state validation
- Public auth helpers and working `AUTHENTICATE` support for PLAIN, LOGIN, EXTERNAL, ANONYMOUS, CRAM-MD5, XOAUTH2, and OAUTHBEARER
- Public wire encoder/decoder primitives
- Backend-agnostic store interfaces with full Mailbox vtable (info, getMessages, setFlags, copy, expunge, search, listUids, move) and ProtocolAdapter for seq/UID translation
- Store backends: memstore (full operations), fsstore (per-message file storage with UID tracking, flags, subscriptions), pgstore (UID tracking, flag operations, copy, expunge, status queries)
- Middleware and server connection/session building blocks for future dispatcher refactors
- Basic authenticated client pooling with idle reuse
- SORT and THREAD command support with basic message-based ordering and threading
- ACL commands (GETACL, SETACL, DELETEACL, LISTRIGHTS, MYRIGHTS) backed by mailbox ACL state
- QUOTA commands (GETQUOTA, SETQUOTA, GETQUOTAROOT) backed by per-user quota state
- METADATA commands (GETMETADATA, SETMETADATA) backed by mailbox metadata state
- STARTTLS with actual TLS upgrade via `std.crypto.tls.Client` (client) and callback-based upgrade (server); implicit TLS (`connectTls`, `listenAndServeTls`), dynamic capability advertisement, and LOGINDISABLED enforcement
- COMPRESS=DEFLATE command stub
- UNAUTHENTICATE for session reset
- REPLACE for atomic message replacement
- Literal+/Literal- marker parsing (RFC 7888)
- Extended SEARCH criteria: LARGER, SMALLER, HEADER, KEYWORD, UNKEYWORD, date-based filters
- FETCH ENVELOPE with RFC 2822 address parsing
- FETCH body section extraction (HEADER, TEXT, HEADER.FIELDS, HEADER.FIELDS.NOT, partial ranges)
- Graceful server shutdown and connection tracking
- Middleware integration with dispatcher (wrap, wrapAll)
- Store helper utilities (pattern matching, number set resolution, INBOX normalization)
- RFC 2822 address parsing in store adapter
- Server infrastructure: Options, Dispatcher, specialized Writers (FetchWriter, ListWriter, UpdateWriter, ExpungeWriter, MoveWriter), and Trackers (MailboxTracker, SessionTracker)
- Client UID command variants: `uidFetch`, `uidStore`, `uidCopy`, `uidMove`, `uidExpunge`, `uidSearch`, `uidSort`
- Client capability convenience methods: `hasCap`, `supportsIdle`, `supportsMove`, etc.
- Extended types: `CreateOptions`, `StoreOptions`, `NamespaceData`, `IMAPError`, `ListReturnMetadata`, `SearchReturnPartial`, `MultiSearchResult`
- Enhanced `AppendOptions` (binary, utf8), `ListOptions`/`ListData` (extended return options), `SelectOptions` (condstore, qresync), `StatusOptions`/`StatusData` (append_limit, deleted, mailbox_id)
- Test harness module (`imaptest`) with `Harness` and `MockSession`
- Proxy example (`examples/proxy.zig`)

Planned next:

- COMPRESS=DEFLATE actual compression layer
- Richer FETCH/BODYSTRUCTURE parsing
- IMAP4rev2-specific behavior tightening
- Full CONDSTORE/QRESYNC mod-sequence tracking

## Installation

Add `imap.zig` to your `build.zig.zon`:

```zig
.dependencies = .{
    .imap = .{
        .url = "https://github.com/meszmate/imap.zig/archive/refs/heads/main.tar.gz",
        .hash = "...",
    },
},
```

Then wire it into `build.zig`:

```zig
const imap_dep = b.dependency("imap", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("imap", imap_dep.module("imap"));
```

## Quick Start

### Client

```zig
const std = @import("std");
const imap = @import("imap");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var client = try imap.client.Client.connectTcp(gpa.allocator(), "127.0.0.1", 1143);
    defer client.deinit();

    _ = try client.capability();
    try client.login("user", "password");

    const inbox = try client.select("INBOX");
    std.debug.print("INBOX has {d} messages\n", .{inbox.exists});

    try client.logout();
}
```

### Server

```zig
const std = @import("std");
const imap = @import("imap");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var store = imap.store.MemStore.init(gpa.allocator());
    defer store.deinit();
    try store.addUser("user", "password");

    var server = imap.server.Server.init(gpa.allocator(), &store);
    try server.listenAndServe("127.0.0.1:1143");
}
```

## Project Layout

```text
src/root.zig           Public package entrypoint
src/types.zig          Shared IMAP protocol types
src/numset.zig         Sequence-set and UID-set parsing
src/response.zig       Tagged and untagged status parsing
src/wire/              Transport, line reader, modified UTF-7
src/auth/              SASL/auth mechanism helpers
src/client/            Synchronous IMAP client
src/server/            Command dispatcher, writers, trackers, and TCP server loop
src/store/             In-memory, filesystem, and generic store interfaces
src/state/             Connection state machine
src/extension/         Extension metadata and dependency registry
src/middleware/        Middleware chain and built-in middleware
src/imaptest.zig       Test harness with Harness and MockSession
examples/              Client, server, and proxy examples
tests/                 Protocol, client, server, store, middleware, state, and extension tests
```

## Development

```bash
zig build
zig build test
./zig-out/bin/simple_server
./zig-out/bin/simple_client 127.0.0.1 1143 user password
```

Contribution guidance lives in [CONTRIBUTING.md](/Users/meszmate/imap.zig/CONTRIBUTING.md).

## Research Notes

The protocol surface and command set were shaped against:

- [RFC 9051: IMAP4rev2](https://www.rfc-editor.org/rfc/rfc9051.html)
- [RFC 3501: IMAP4rev1](https://www.rfc-editor.org/rfc/rfc3501.html)
- [RFC 2177: IDLE](https://www.rfc-editor.org/rfc/rfc2177.html)
- [RFC 4315: UIDPLUS](https://www.rfc-editor.org/rfc/rfc4315.html)
- [RFC 2342: NAMESPACE](https://www.rfc-editor.org/rfc/rfc2342.html)
- [RFC 2971: ID](https://www.rfc-editor.org/rfc/rfc2971.html)
- [RFC 5161: ENABLE](https://www.rfc-editor.org/rfc/rfc5161.html)
- [RFC 5256: SORT and THREAD](https://www.rfc-editor.org/rfc/rfc5256.html)
- [RFC 4314: ACL](https://www.rfc-editor.org/rfc/rfc4314.html)
- [RFC 9208: QUOTA](https://www.rfc-editor.org/rfc/rfc9208.html)
- [RFC 5464: METADATA](https://www.rfc-editor.org/rfc/rfc5464.html)
- [RFC 4978: COMPRESS=DEFLATE](https://www.rfc-editor.org/rfc/rfc4978.html)
- [RFC 7888: LITERAL+](https://www.rfc-editor.org/rfc/rfc7888.html)
- [RFC 8437: UNAUTHENTICATE](https://www.rfc-editor.org/rfc/rfc8437.html)
- [RFC 8508: REPLACE](https://www.rfc-editor.org/rfc/rfc8508.html)
- [IANA IMAP Capabilities Registry](https://www.iana.org/assignments/imap-capabilities/imap-capabilities.xhtml)
- [IANA IMAP Response Codes Registry](https://www.iana.org/assignments/imap-response-codes/imap-response-codes.xhtml)
- [IANA IMAP Mailbox Name Attributes Registry](https://www.iana.org/assignments/imap-mailbox-name-attributes/imap-mailbox-name-attributes.xhtml)

The package structure was also informed by the local `~/imap-go` reference implementation, especially its split between protocol types, client/server layers, state handling, and extension registration.
