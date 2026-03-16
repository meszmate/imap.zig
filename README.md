# imap.zig

[![CI](https://github.com/meszmate/imap.zig/actions/workflows/ci.yml/badge.svg)](https://github.com/meszmate/imap.zig/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

`imap.zig` is a zero-dependency IMAP library for Zig inspired by the shape of `imap-go`, built around a reusable protocol core plus a synchronous client and in-memory server.

It is designed as a practical foundation for both IMAP tooling and embedded mail services:

- IMAP4rev1-oriented protocol types, status parsing, number set parsing, and modified UTF-7 mailbox handling
- Synchronous client with greeting parsing, tagged command execution, and helpers for `CAPABILITY`, `LOGIN`, `SELECT`/`EXAMINE`, `LIST`, `STATUS`, `APPEND`, `SEARCH`, `FETCH`, and `LOGOUT`
- In-memory server and store with core commands including `CAPABILITY`, `NOOP`, `LOGOUT`, `LOGIN`, `NAMESPACE`, `ID`, `LIST`, `CREATE`, `DELETE`, `RENAME`, `SUBSCRIBE`, `UNSUBSCRIBE`, `SELECT`, `EXAMINE`, `STATUS`, `APPEND`, `UNSELECT`, `CLOSE`, `SEARCH`, `FETCH`, `STORE`, `COPY`, `MOVE`, and `EXPUNGE`
- Transport abstraction for testing, scripting, and custom I/O
- GitHub Actions CI, examples, and unit tests

## Status

This repository is a strong first release, not the end of the protocol surface.

Implemented now:

- Core IMAP4rev1 command flow over plain TCP
- Modified UTF-7 encode/decode
- In-memory mailbox store and message flag management
- Sequence-set and UID-set parsing
- Core command parsing and response generation

Planned next:

- TLS and STARTTLS helpers
- SASL/auth mechanism modules
- IDLE and asynchronous update handling
- richer `FETCH`/`BODYSTRUCTURE` parsing
- extension registry and more RFC extensions

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
src/client/            Synchronous IMAP client
src/server/            Command dispatcher and TCP server loop
src/store/             In-memory store backend
examples/              Simple client and server examples
tests/                 Protocol, client, and server tests
```

## Development

```bash
zig build
zig build test
./zig-out/bin/simple_server
./zig-out/bin/simple_client 127.0.0.1 1143 user password
```

## Research Notes

The protocol surface and command set were shaped against:

- [RFC 9051: IMAP4rev2](https://www.rfc-editor.org/rfc/rfc9051.html)
- [RFC 3501: IMAP4rev1](https://www.rfc-editor.org/rfc/rfc3501.html)
- [RFC 2177: IDLE](https://www.rfc-editor.org/rfc/rfc2177.html)
- [RFC 4315: UIDPLUS](https://www.rfc-editor.org/rfc/rfc4315.html)

The package structure was also informed by the local `~/imap-go` reference implementation.
