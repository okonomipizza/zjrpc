const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const JsonStream = @import("io.zig").JsonStream;
const RequestObject = @import("types.zig").RequestObject;

pub const RpcClient = struct {
    address: std.net.Address,
    stream: JsonStream,
    buf: []u8,
    allocator: Allocator,

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

    pub fn call(self: *RpcClient, request: *RequestObject) ![]const u8 {
        const socket = try self.bind();
        defer std.posix.close(socket);

        const request_json = try request.toJson();
        try self.stream.writeMessage(request_json, socket);
        const response = try self.stream.readMessage(socket);

        return response;
    }

    pub fn cast(self: *RpcClient, request: *RequestObject) !void {
        const socket = try self.bind();
        defer std.posix.close(socket);

        const request_json = try request.toJson();

        try self.stream.writeMessage(request_json, socket);
    }
};
