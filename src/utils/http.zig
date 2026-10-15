//! Minimal blocking HTTP JSON POST helper (std.http.Client, std only).
//!
//! std.http.Client does not expose an end-to-end request/read timeout through
//! request(). To keep an LLM endpoint that accepts and never responds from
//! blocking the calling thread forever, the exchange runs on a worker
//! thread and the caller gives up after a deadline. An abandoned worker is
//! detached because this std version cannot cancel a blocking HTTP call; it
//! owns all of its memory until it exits.

const std = @import("std");
const builtin = @import("builtin");

pub const Header = std.http.Header;

/// Deadline for TCP/TLS connection setup (before the request body is sent).
const CONNECT_TIMEOUT_MS: u64 = 10_000;
/// Deadline for the response after the connection is up.
const READ_TIMEOUT_MS: u64 = 30_000;
const POLL_MS: u64 = 10;

const Phase = enum(u8) { connecting, connected, done };

const Result = struct {
    body: ?[]u8 = null, // worker-owned until copied; null = err below
    err: anyerror = error.HttpTimeout,
};

/// Everything the worker touches is page_allocator-owned and reference-counted
/// so it remains valid until a detached worker exits.
const Shared = struct {
    phase: std.atomic.Value(u8),
    references: std.atomic.Value(usize),
    result: Result,
    url: []u8,
    headers: []Header,
    body: []u8,
};

// Lets the timeout regression wait until detached workers have freed Shared.
var completed_shared_count = std.atomic.Value(usize).init(0);
var completed_response_count = std.atomic.Value(usize).init(0);

// Timed-out workers can overlap later requests, so keep a thread-safe I/O
// context alive for the process lifetime.
const HttpIoState = enum(u8) { uninitialized, initializing, ready };
var http_io_state = std.atomic.Value(HttpIoState).init(.uninitialized);
var http_io_threaded: std.Io.Threaded = .init_single_threaded;

fn httpIo() std.Io {
    if (http_io_state.cmpxchgStrong(.uninitialized, .initializing, .acq_rel, .monotonic) == null) {
        http_io_threaded = .init(std.heap.page_allocator, .{});
        http_io_state.store(.ready, .release);
    } else {
        while (http_io_state.load(.acquire) != .ready) std.atomic.spinLoopHint();
    }
    return http_io_threaded.io();
}

/// POST `body` to `url` with the given headers and return the response body
/// (caller owns). Non-2xx status -> error.HttpStatus (status printed).
/// A hang (connect or read) -> error.HttpTimeout after the deadlines above.
pub fn postJson(
    allocator: std.mem.Allocator,
    url: []const u8,
    headers: []const Header,
    body: []const u8,
) ![]u8 {
    return postJsonWithTimeouts(allocator, url, headers, body, CONNECT_TIMEOUT_MS, READ_TIMEOUT_MS);
}

fn postJsonWithTimeouts(
    allocator: std.mem.Allocator,
    url: []const u8,
    headers: []const Header,
    body: []const u8,
    connect_timeout_ms: u64,
    read_timeout_ms: u64,
) ![]u8 {
    const io = httpIo();
    const pa = std.heap.page_allocator;

    const shared = shared_block: {
        const duped_headers = dupHeaders(headers) catch return error.HttpTimeout;
        errdefer freeHeaders(duped_headers);
        const duped_url = pa.dupe(u8, url) catch return error.HttpTimeout;
        errdefer pa.free(duped_url);
        const duped_body = pa.dupe(u8, body) catch return error.HttpTimeout;
        errdefer pa.free(duped_body);
        const block = pa.create(Shared) catch return error.HttpTimeout;
        block.* = .{
            .phase = std.atomic.Value(u8).init(@backingInt(Phase.connecting)),
            .references = std.atomic.Value(usize).init(2), // caller and worker
            .result = .{},
            .url = duped_url,
            .headers = duped_headers,
            .body = duped_body,
        };
        break :shared_block block;
    };

    const t = std.Thread.spawn(.{}, worker, .{ io, shared }) catch {
        releaseShared(shared);
        releaseShared(shared);
        return error.HttpTimeout;
    };

    // Wait for TCP/TLS connect, then for the response.
    if (!waitForPhase(io, shared, @backingInt(Phase.connected), connect_timeout_ms)) {
        t.detach();
        releaseShared(shared);
        return error.HttpTimeout;
    }
    if (!waitForPhase(io, shared, @backingInt(Phase.done), read_timeout_ms)) {
        t.detach();
        releaseShared(shared);
        return error.HttpTimeout;
    }
    t.join();
    defer releaseShared(shared);
    if (shared.result.body) |b| return allocator.dupe(u8, b);
    return shared.result.err;
}

/// Run the whole exchange; the caller only resumes after phase == done.
fn worker(io: std.Io, shared: *Shared) void {
    defer releaseShared(shared);
    const allocator = std.heap.page_allocator;
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const uri = std.Uri.parse(shared.url) catch {
        shared.result.err = error.InvalidUri;
        shared.phase.store(@backingInt(Phase.done), .release);
        return;
    };
    var req = client.request(.POST, uri, .{ .extra_headers = shared.headers }) catch |err| {
        shared.result.err = err;
        shared.phase.store(@backingInt(Phase.done), .release);
        return;
    };
    defer req.deinit();
    // Connected: the caller's connect deadline stops here.
    shared.phase.store(@backingInt(Phase.connected), .release);

    req.sendBodyComplete(shared.body) catch |err| {
        shared.result.err = err;
        shared.phase.store(@backingInt(Phase.done), .release);
        return;
    };

    var redirect_buf: [8192]u8 = undefined;
    // nit-8: std.http forwards request headers (including Authorization) on
    // 3xx redirects to the redirect target. groq/openai/ollama never redirect
    // POSTs, so the bearer key never leaves the trusted endpoint; acceptable.
    var resp = req.receiveHead(&redirect_buf) catch |err| {
        shared.result.err = err;
        shared.phase.store(@backingInt(Phase.done), .release);
        return;
    };

    const status = resp.head.status;
    if (status.class() != .success) {
        std.debug.print("postJson {s}: status {d} {s}\n", .{
            shared.url, @backingInt(status), status.phrase() orelse "",
        });
        shared.result.err = error.HttpStatus;
        shared.phase.store(@backingInt(Phase.done), .release);
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
        shared.phase.store(@backingInt(Phase.done), .release);
        return;
    };
    if (builtin.is_test) _ = completed_response_count.fetchAdd(1, .release);
    shared.phase.store(@backingInt(Phase.done), .release);
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

/// The final owner frees the worker's request copies and any late response.
fn releaseShared(shared: *Shared) void {
    if (shared.references.fetchSub(1, .acq_rel) != 1) return;
    const pa = std.heap.page_allocator;
    if (shared.result.body) |response| pa.free(response);
    freeHeaders(shared.headers);
    pa.free(shared.url);
    pa.free(shared.body);
    pa.destroy(shared);
    if (builtin.is_test) _ = completed_shared_count.fetchAdd(1, .release);
}

fn freeHeaders(headers: []Header) void {
    const pa = std.heap.page_allocator;
    for (headers) |h| {
        pa.free(h.name);
        pa.free(h.value);
    }
    pa.free(headers);
}

test "postJson: late response survives caller arena reset and teardown" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var addr = std.Io.net.IpAddress{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var server = try addr.listen(io, .{ .kernel_backlog = 2 });
    const port = server.socket.address.getPort();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var arena_alive = true;
    defer if (arena_alive) arena.deinit();
    var tracked = TrackingAllocator{ .backing = arena.allocator() };

    const ServerContext = struct {
        fn run(io_t: std.Io, srv: *std.Io.net.Server) void {
            const first = srv.accept(io_t) catch return;
            const delayed = std.Thread.spawn(.{}, reply, .{ io_t, first, 1_500, "late" }) catch {
                first.close(io_t);
                return;
            };
            const second = srv.accept(io_t) catch {
                delayed.join();
                return;
            };
            reply(io_t, second, 0, "second");
            delayed.join();
        }

        fn reply(io_t: std.Io, stream: std.Io.net.Stream, delay_ms: u64, response: []const u8) void {
            defer stream.close(io_t);
            var in_buf: [4096]u8 = undefined;
            var out_buf: [4096]u8 = undefined;
            var reader = stream.reader(io_t, &in_buf);
            var writer = stream.writer(io_t, &out_buf);
            var http_server = std.http.Server.init(&reader.interface, &writer.interface);
            var req = http_server.receiveHead() catch return;
            if (delay_ms != 0) {
                io_t.sleep(.{ .nanoseconds = @as(i96, @intCast(delay_ms)) * std.time.ns_per_ms }, .awake) catch return;
            }
            req.respond(response, .{ .keep_alive = false }) catch return;
            var drain_buf: [4096]u8 = undefined;
            while (true) {
                const nread = reader.interface.readSliceShort(&drain_buf) catch return;
                if (nread < drain_buf.len) break;
            }
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerContext.run, .{ io, &server });
    var server_finished = false;
    defer if (!server_finished) {
        server.deinit(io);
        server_thread.join();
    };

    const request_allocator = tracked.allocator();
    const url = try std.fmt.allocPrint(request_allocator, "http://127.0.0.1:{d}/", .{port});
    const headers = try request_allocator.alloc(Header, 1);
    headers[0] = .{
        .name = try request_allocator.dupe(u8, "X-Test"),
        .value = try request_allocator.dupe(u8, "request"),
    };
    const body = try request_allocator.dupe(u8, "{}");

    const completed_before = completed_shared_count.load(.acquire);
    const completed_responses_before = completed_response_count.load(.acquire);
    try std.testing.expectError(
        error.HttpTimeout,
        postJsonWithTimeouts(request_allocator, url, headers, body, 1_000, 1_000),
    );
    tracked.expired.store(true, .release);
    _ = arena.reset(.retain_capacity);
    arena.deinit();
    arena_alive = false;

    var next_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer next_arena.deinit();
    const next_url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/", .{port});
    defer std.testing.allocator.free(next_url);
    const response = try postJson(next_arena.allocator(), next_url, &.{}, "{}");
    try std.testing.expectEqualStrings("second", response);
    _ = next_arena.reset(.retain_capacity);

    server.deinit(io);
    server_thread.join();
    server_finished = true;

    const deadline = std.Io.Timestamp.now(io, .awake).addDuration(.{
        .nanoseconds = @as(i96, 2_000) * std.time.ns_per_ms,
    });
    while (completed_shared_count.load(.acquire) < completed_before + 2 or
        completed_response_count.load(.acquire) < completed_responses_before + 2)
    {
        if (std.Io.Timestamp.now(io, .awake).nanoseconds >= deadline.nanoseconds) return error.WorkerCleanupTimeout;
        io.sleep(.{ .nanoseconds = @as(i96, POLL_MS) * std.time.ns_per_ms }, .awake) catch return error.WorkerCleanupTimeout;
    }
    try std.testing.expectEqual(@as(usize, 0), tracked.late_accesses.load(.acquire));
}

const TrackingAllocator = struct {
    backing: std.mem.Allocator,
    expired: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    late_accesses: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocator(self: *TrackingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn record(self: *TrackingAllocator) bool {
        if (!self.expired.load(.acquire)) return false;
        _ = self.late_accesses.fetchAdd(1, .monotonic);
        return true;
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(context));
        if (self.record()) return null;
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *TrackingAllocator = @ptrCast(@alignCast(context));
        if (self.record()) return false;
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(context));
        if (self.record()) return null;
        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *TrackingAllocator = @ptrCast(@alignCast(context));
        if (self.record()) return;
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};
