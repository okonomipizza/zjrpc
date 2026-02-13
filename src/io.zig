const std = @import("std");
const posix = std.posix;

/// A stream wrapper for sending and receiving JSON-RPC messages over TCP.
///
/// Message format:
/// ```
/// [4-byte little-endian length prefix][JSON payload]
/// ```
/// Transparently handles TCP packet fragmentation and reassembly
/// using an internal bufrfer.
pub const JsonStream = struct {
    /// Read buffer
    buf: []u8,
    /// Start position of unprocessed data
    start: usize = 0,
    /// End position of data written into the buffer.
    pos: usize = 0,

    /// Initializes a `JsonStream` with the given buffer.
    /// Ownership of the buffer remains with the caller.
    pub fn init(buf: []u8) JsonStream {
        return .{
            .buf = buf,
            .start = 0,
            .pos = 0,
        };
    }

    /// Reads a single complete JSON message from the socket.
    /// The caller is responsible for parsing the returned bytes into either a
    /// JSON-RPC `RequestObject` or `ResponseObject` depending on the context
    /// (e.g. server-side expects requests, client-side expects responses).
    pub fn readMessage(self: *JsonStream, socket: posix.socket_t) ![]u8 {
        var buf = self.buf;
        while (true) {
            if (try self.bufferedMessage()) |msg| {
                return msg;
            }
            const pos = self.pos;
            const n = try posix.read(socket, buf[pos..]);
            if (n == 0) {
                return error.Closed;
            }
            self.pos = pos + n;
        }
    }

    fn bufferedMessage(self: *JsonStream) !?[]u8 {
        const buf = self.buf;
        const pos = self.pos;
        const start = self.start;
        std.debug.assert(pos >= start);
        const unprocessed = buf[start..pos];

        if (unprocessed.len < 4) {
            self.ensureSpace(4 - unprocessed.len) catch unreachable;
            return null;
        }

        const message_len = std.mem.readInt(u32, unprocessed[0..4], .little);
        const total_len = message_len + 4;

        if (unprocessed.len < total_len) {
            try self.ensureSpace(total_len);
            return null;
        }

        self.start += total_len;
        return unprocessed[4..total_len];
    }

    fn ensureSpace(self: *JsonStream, space: usize) error{BufferTooSmall}!void {
        const buf = self.buf;
        if (buf.len < space) {
            return error.BufferTooSmall;
        }

        const start = self.start;
        const spare = buf.len - start;
        if (spare >= space) return;

        const unprocessed = buf[start..self.pos];
        std.mem.copyForwards(u8, buf[0..unprocessed.len], unprocessed);
        self.start = 0;
        self.pos = unprocessed.len;
    }

    /// Sends a JSON message to the socket.
    /// Prepends a 4-byte little-endian length prefix before the payload.
    pub fn writeMessage(self: *JsonStream, msg: []const u8, socket: posix.socket_t) !void {
        _ = self;
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, @intCast(msg.len), .little);

        var vec = [2]posix.iovec_const{
            .{ .len = 4, .base = &buf },
            .{ .len = msg.len, .base = msg.ptr },
        };

        try writeAllVectored(socket, &vec);
    }

    fn writeAllVectored(socket: posix.socket_t, vec: []posix.iovec_const) !void {
        var i: usize = 0;
        while (true) {
            var n = try posix.writev(socket, vec[i..]);
            while (n >= vec[i].len) {
                n -= vec[i].len;
                i += 1;
                if (i >= vec.len) return;
            }
            vec[i].base += n;
            vec[i].len -= n;
        }
    }
};
