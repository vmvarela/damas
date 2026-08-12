//! Minimal blocking HTTP JSON POST helper (std.http.Client, std only).

const std = @import("std");

pub const Header = std.http.Header;

/// POST `body` to `url` with the given headers and return the response body
/// (caller owns). Non-2xx status -> error.HttpStatus (status printed).
pub fn postJson(
    allocator: std.mem.Allocator,
    url: []const u8,
    headers: []const Header,
    body: []const u8,
) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var req = try client.request(.POST, uri, .{ .extra_headers = headers });
    defer req.deinit();

    try req.sendBodyComplete(@constCast(body));

    var redirect_buf: [8192]u8 = undefined;
    // nit-8: std.http forwards request headers (including Authorization) on
    // 3xx redirects to the redirect target. groq/openai/ollama never redirect
    // POSTs, so the bearer key never leaves the trusted endpoint; acceptable.
    var resp = try req.receiveHead(&redirect_buf);

    const status = resp.head.status;
    if (status.class() != .success) {
        std.debug.print("postJson {s}: status {d} {s}\n", .{
            url, @intFromEnum(status), status.phrase() orelse "",
        });
        return error.HttpStatus;
    }

    // groq/openai gzip the response even when the client doesn't advertise
    // it — read through the stdlib decompressor so Content-Encoding (gzip,
    // deflate, zstd) is handled transparently.
    var transfer_buf: [16384]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var decompress_buf: [65536]u8 = undefined;
    var reader = resp.readerDecompressing(&transfer_buf, &decompress, &decompress_buf);
    return reader.allocRemaining(allocator, .limited(0x100000));
}
