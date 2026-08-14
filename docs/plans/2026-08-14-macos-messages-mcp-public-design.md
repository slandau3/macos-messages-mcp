# macOS Messages MCP public package design

## Goal

Publish a neutral, source-only macOS Messages MCP project that other Mac users can inspect, build, and configure without receiving any private Messages data or machine-specific installation artifacts.

## Scope

The public package exposes six read-only MCP tools:

- database health and schema diagnostics;
- chat listing and aggregate counts;
- plain-text message search;
- recent messages;
- messages for a selected chat;
- aggregate message statistics.

The package does not send, edit, delete, or mark messages, expose attachments, run arbitrary SQL, read arbitrary paths, or provide a network listener.

## Permission boundary

The database reader is a native Swift executable inside a background-only app bundle. The MCP client starts a separate stdio proxy. The proxy has no database logic and launches the worker through LaunchServices, allowing Full Disk Access to be assigned to the app bundle rather than to Node.js, Python, a terminal, or the MCP client.

SQLite connections use read-only flags and `PRAGMA query_only = ON`. Queries are fixed and parameterized. When WAL sidecars exist, the worker copies the main database and both sidecars into a private temporary directory, verifies that the source metadata is stable, and reads the private snapshot.

## Transport and lifecycle

The proxy speaks newline-delimited JSON-RPC 2.0 over stdio. It creates a random `0600` Unix socket and a one-use token, launches the app worker, authenticates the worker, and relays bytes until the MCP client closes the pipe. No daemon, launch agent, menu-bar item, window, TCP listener, or background database index is required.

## Public-repository hygiene

The repository includes source, synthetic fixture tests, build scripts, documentation, and a `.gitignore`. It excludes `.build`, app bundles, signed binaries, local logs, database files, WAL/SHM sidecars, message exports, contacts, credentials, and absolute machine paths. Fixture identifiers use reserved or fictional values.

## Verification plan

Before publishing:

1. Run the self-contained Swift test harness and require zero failures.
2. Build both release executables and the app bundle.
3. Verify the bundle's ad-hoc signature.
4. Perform a privacy scan over every tracked candidate file.
5. Review the staged diff and repository file list.
6. Create the GitHub repository only after local verification succeeds.
