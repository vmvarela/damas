//! Minimal blocking HTTP JSON POST helper (std.http.Client, std only).
//!
//! 0.16.0's std.http.Client has no timeout support: there are no
//! connect_timeout_ms / read_timeout_ms client fields and no timeout on
//! request(); the ConnectTcpOptions.timeout field exists but is
//! unimplemented (Threaded's netConnectIpPosix panics "TODO" when it is
//! set). To keep an LLM endpoint that accepts and never responds from
//! blocking the calling thread forever, the exchange runs on a worker
//! thread and the caller gives up after a deadline. An abandoned worker is
//! detached and leaks (thread + its page_allocator shared block) — the only
//! way to cancel a blocking std.http call in this std version.

const std = @import("std");

pub const Header = std.http.Header;

/// Deadline for TCP/TLS connection setup (before the request body is sent).
const CONNECT_TIMEOUT_MS: u64 = 10_000;
/// Deadline for the response after the connection is up.
const READ_TIMEOUT_MS: u64 = 30_000;
const POLL_MS: u64 = 10;

const Phase = enum(u8) { connecting, connected, done };

const Result = struct {
    body: ?[]u8 = null, // caller-owned on success; null = err below
    err: anyerror = error.HttpTimeout,
};

/// Everything the worker touches that must outlive a timeout return. The
/// caller frees url/headers/body while unwinding error.HttpTimeout, so the
/// worker reads its own page_allocator copies; the response is allocated
/// from the caller's allocator (page_allocator in practice — thread-safe
/// if the worker is still running after the caller gives up).
const Shared = struct {
    phase: std.atomic.Value(u8),
    result: Result,
    url: []u8,
    headers: []Header,
    body: []u8,
    caller_allocator: std.mem.Allocator,
};

/// POST `body` to `url` with the given headers and return the response body
/// (caller owns). Non-2xx status -> error.HttpStatus (status printed).
/// A hang (connect or read) -> error.HttpTimeout after the deadlines above.
pub fn postJson(
    allocator: std.mem.Allocator,
    url: []const u8,
    headers: []const Header,
    body: []const u8,
) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();

    // Deep-copy the request into page_allocator memory before spawning: on
    // the timeout path the caller has already returned and freed its own
    // slices, but the worker may still be reading them.
    const duped_headers = dupHeaders(headers) catch return error.HttpTimeout;
    const shared = std.heap.page_allocator.create(Shared) catch return error.HttpTimeout;
    shared.* = .{
        .phase = std.atomic.Value(u8).init(@intFromEnum(Phase.connecting)),
        .result = .{},
        .url = std.heap.page_allocator.dupe(u8, url) catch return error.HttpTimeout,
        .headers = duped_headers,
        .body = std.heap.page_allocator.dupe(u8, body) catch return error.HttpTimeout,
        .caller_allocator = allocator,
    };

    const t = std.Thread.spawn(.{}, worker, .{ io, shared }) catch {
        freeShared(shared);
        return error.HttpTimeout;
    };

    // Wait for TCP/TLS connect, then for the response.
    if (!waitForPhase(io, shared, @intFromEnum(Phase.connected), CONNECT_TIMEOUT_MS)) {
        t.detach(); // ponytail: worker + shared leak — it can't be canceled
        return error.HttpTimeout;
    }
    if (!waitForPhase(io, shared, @intFromEnum(Phase.done), READ_TIMEOUT_MS)) {
        t.detach();
        return error.HttpTimeout;
    }
    t.join();
    defer freeShared(shared);
    if (shared.result.body) |b| return b;
    return shared.result.err;
}

/// Run the whole exchange; the caller only resumes after phase == done.
fn worker(io: std.Io, shared: *Shared) void {
    const allocator = shared.caller_allocator;
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const uri = std.Uri.parse(shared.url) catch {
        shared.result.err = error.InvalidUri;
        shared.phase.store(@intFromEnum(Phase.done), .release);
        return;
    };
    var req = client.request(.POST, uri, .{ .extra_headers = shared.headers }) catch |err| {
        shared.result.err = err;
        shared.phase.store(@intFromEnum(Phase.done), .release);
        return;
    };
    defer req.deinit();
    // Connected: the caller's connect deadline stops here.
    shared.phase.store(@intFromEnum(Phase.connected), .release);

    req.sendBodyComplete(shared.body) catch |err| {
        shared.result.err = err;
        shared.phase.store(@intFromEnum(Phase.done), .release);
        return;
    };

    var redirect_buf: [8192]u8 = undefined;
    // nit-8: std.http forwards request headers (including Authorization) on
    // 3xx redirects to the redirect target. groq/openai/ollama never redirect
    // POSTs, so the bearer key never leaves the trusted endpoint; acceptable.
    var resp = req.receiveHead(&redirect_buf) catch |err| {
        shared.result.err = err;
        shared.phase.store(@intFromEnum(Phase.done), .release);
        return;
    };

    const status = resp.head.status;
    if (status.class() != .success) {
        std.debug.print("postJson {s}: status {d} {s}\n", .{
            shared.url, @intFromEnum(status), status.phrase() orelse "",
        });
        shared.result.err = error.HttpStatus;
        shared.phase.store(@intFromEnum(Phase.done), .release);
        return;
    }

    // groq/openai gzip the response even when the client doesn't advertise
    // it — read through the stdlib decompressor so Content-Encoding (gzip,
    // deflate, zstd) is handled transparently.
    var transfer_buf: [16384]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var decompress_buf: [65536]u8 = undefined;
    var reader = resp.readerDecompressing(&transfer_buf, &decompress, &decompress_buf);
    shared.result.body = reader.allocRemaining(allocator, .limited(0x100000)) catch |err| {
        shared.result.err = err;
        shared.phase.store(@intFromEnum(Phase.done), .release);
        return;
    };
    shared.phase.store(@intFromEnum(Phase.done), .release);
}

fn waitForPhase(io: std.Io, shared: *Shared, min: u8, timeout_ms: u64) bool {
    const deadline = std.Io.Timestamp.now(io, .awake).addDuration(.{
        .nanoseconds = @as(i96, @intCast(timeout_ms)) * std.time.ns_per_ms,
    });
    while (shared.phase.load(.acquire) < min) {
        if (std.Io.Timestamp.now(io, .awake).nanoseconds >= deadline.nanoseconds) return false;
        io.sleep(.{ .nanoseconds = @as(i96, POLL_MS) * std.time.ns_per_ms }, .awake) catch
            return false;
    }
    return true;
}

/// page_allocator copies of the header names/values (never the caller's).
fn dupHeaders(headers: []const Header) ![]Header {
    const pa = std.heap.page_allocator;
    const out = try pa.alloc(Header, headers.len);
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |h| {
            pa.free(h.name);
            pa.free(h.value);
        }
        pa.free(out);
    }
    for (headers) |h| {
        const name = try pa.dupe(u8, h.name);
        errdefer pa.free(name);
        const value = try pa.dupe(u8, h.value);
        errdefer pa.free(value);
        out[n] = .{ .name = name, .value = value };
        n += 1;
    }
    return out;
}

/// Free a Shared block and its copies. Only safe when the worker is not
/// running (join or spawn-failure path).
fn freeShared(shared: *Shared) void {
    const pa = std.heap.page_allocator;
    for (shared.headers) |h| {
        pa.free(h.name);
        pa.free(h.value);
    }
    pa.free(shared.headers);
    pa.free(shared.url);
    pa.free(shared.body);
    pa.destroy(shared);
}
