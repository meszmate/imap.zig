# Contributing

Thanks for contributing to `imap.zig`.

## Development Setup

- Install Zig `0.15.2` or newer compatible with [build.zig.zon](/Users/meszmate/imap.zig/build.zig.zon).
- Clone the repository and work from the repo root.
- Run:

```bash
zig build
zig build test
```

## Project Structure

- [src/types.zig](/Users/meszmate/imap.zig/src/types.zig): shared protocol data types
- [src/wire/](/Users/meszmate/imap.zig/src/wire): transport, line parsing, modified UTF-7
- [src/auth/](/Users/meszmate/imap.zig/src/auth): SASL/auth mechanism helpers
- [src/client/](/Users/meszmate/imap.zig/src/client): synchronous client API
- [src/server/](/Users/meszmate/imap.zig/src/server): command dispatcher, connection/session helpers, and server loop
- [src/store/](/Users/meszmate/imap.zig/src/store): in-memory, filesystem, and generic storage interfaces
- [src/state/](/Users/meszmate/imap.zig/src/state): connection state machine
- [src/extension/](/Users/meszmate/imap.zig/src/extension): extension metadata and registry
- [src/middleware/](/Users/meszmate/imap.zig/src/middleware): middleware chain primitives and built-in middleware
- [tests/](/Users/meszmate/imap.zig/tests): protocol, auth, client, server, store, middleware, state, and extension tests

## Guidelines

- Keep the library dependency-free in core code.
- Prefer protocol correctness over convenience shortcuts.
- Add tests for new parser behavior, command handling, or state transitions.
- Preserve ASCII by default in source files unless there is a clear need otherwise.
- Keep public APIs small and composable.

## Feature Work

When adding new IMAP functionality:

1. Check the relevant RFC and, when applicable, the IANA IMAP registries.
2. Update protocol constants/types first.
3. Add client/server behavior only when the wire semantics are clear.
4. Document implemented versus unimplemented behavior in [README.md](/Users/meszmate/imap.zig/README.md).

## Pull Requests

- Keep PRs focused.
- Include a short description of the protocol or API change.
- Mention any RFCs or registries used.
- Ensure `zig build` and `zig build test` both pass before opening the PR.
