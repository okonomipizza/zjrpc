const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const JsonStream = @import("io.zig").JsonStream;
const RequestObject = @import("types.zig").RequestObject;
const ResponseObject = @import("types.zig").ResponseObject;

/// A JSON-RPC client that communicates over TCP.
///
/// Each `call` or `cast` opens a new TCP connection, sends a request.
/// and closes the connection when done.
pub const RpcClient = struct {
    address: std.net.Address,
    stream: JsonStream,
    buf: []u8,
    allocator: Allocator,

    /// Initializes an `RpcClient` with an internal read buffer of `buf_size` bytes.
    /// The client connects to `address` on each `call` or `cast`.
    pub fn init(allocator: Allocator, buf_size: usize, address: std.net.Address) !RpcClient {
        const buf: []u8 = try allocator.alloc(u8, buf_size);
        const stream = JsonStream.init(buf);

        return .{
            .address = address,
            .stream = stream,
            .buf = buf,
            .allocator = allocator,
        };
    }

    /// Releases the internal read buffer.
    pub fn deinit(self: RpcClient) void {
        self.allocator.free(self.buf);
    }

    fn bind(self: *RpcClient) !std.posix.socket_t {
        const tpe: u32 = posix.SOCK.STREAM;
        const protocol = posix.IPPROTO.TCP;
        const socket = try posix.socket(self.address.any.family, tpe, protocol);
        try posix.connect(socket, &self.address.any, self.address.getOsSockLen());
        return socket;
    }

    /// Sends a JSON-RPC request and waits for a response.
    pub fn call(self: *RpcClient, allocator: Allocator, request: *RequestObject) !*ResponseObject {
        const socket = try self.bind();
        defer std.posix.close(socket);

        try self.sendRequest(socket, request);
        return self.receiveResponse(allocator, socket);
    }

    fn sendRequest(self: *RpcClient, socket: posix.socket_t, request: *RequestObject) !void {
        const json_slice = try request.toJson();
        try self.stream.writeMessage(json_slice, socket);
    }

    fn receiveResponse(self: *RpcClient, allocator: Allocator, socket: posix.socket_t) !*ResponseObject {
        const response_json = try self.stream.readMessage(socket);
        return try ResponseObject.fromSlice(allocator, response_json);
    }

    /// Sends a JSON-RPC request without waiting for a response.
    ///
    /// Suitable for JSON-RPC notification where no response is expected.
    pub fn cast(self: *RpcClient, request: *RequestObject) !void {
        const socket = try self.bind();
        defer std.posix.close(socket);

        try self.sendRequest(socket, request);
    }
};
