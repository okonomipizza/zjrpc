const std = @import("std");
const posix = std.posix;
const net = std.net;
const Allocator = std.mem.Allocator;

const Thread = std.Thread;
const testing = std.testing;

pub const JsonStream = @import("io.zig").JsonStream;
pub const RpcClient = @import("rpc.zig").RpcClient;
pub const RequestObject = @import("types.zig").RequestObject;
pub const ResponseObject = @import("types.zig").ResponseObject;
pub const JsonRpcVersion = @import("types.zig").JsonRpcVersion;
pub const RequestId = @import("types.zig").RequestId;

test "call" {
    const allocator = testing.allocator;

    const server_info = try spawn_server_thread(allocator);
    defer {
        allocator.destroy(server_info.context.address);
        allocator.destroy(server_info.context);
        allocator.destroy(server_info);
    }

    var client = try RpcClient.init(allocator, 4096, server_info.address);
    defer client.deinit();

    var request =
        try RequestObject.init(allocator, JsonRpcVersion.v2, "echo", null, RequestId{ .number = 1 });
    defer request.deinit(allocator);

    const response = try client.call(allocator, request);
    defer response.deinit(allocator);

    try testing.expectEqualStrings("echo", response.ok.result.string);
}

test "notification" {
    const allocator = testing.allocator;

    const server_info = try spawn_server_thread(allocator);
    defer {
        allocator.destroy(server_info.context.address);
        allocator.destroy(server_info.context);
        allocator.destroy(server_info);
    }

    var client = try RpcClient.init(allocator, 1024, server_info.address);
    defer client.deinit();

    const request = try RequestObject.init(allocator, JsonRpcVersion.v2, "test", null, null);
    defer request.deinit(allocator);
    try client.cast(request);
}

const ServerInfo = struct {
    thread: Thread,
    address: std.net.Address,
    context: *ServerContext,
};

const ServerContext = struct {
    address: *std.net.Address,
    allocator: std.mem.Allocator,
};

/// Spawn a server thread and returns the address
/// Caller should destroy ServerInfo
fn spawn_server_thread(allocator: Allocator) !*ServerInfo {
    const address = try allocator.create(std.net.Address);
    address.* = undefined;

    const context = try allocator.create(ServerContext);
    context.* = ServerContext{
        .address = address,
        .allocator = allocator,
    };

    // Spawn a thread
    const thread = try std.Thread.spawn(.{}, serverThreadFn, .{context});
    // Wait a nano seconds until server activated
    std.posix.nanosleep(1, 1000);

    const server_info = try allocator.create(ServerInfo);
    server_info.* = ServerInfo{
        .thread = thread,
        .address = address.*,
        .context = context,
    };
    return server_info;
}

fn serverThreadFn(context: *ServerContext) void {
    runServer(context) catch |err| {
        const allocator = context.allocator;
        allocator.destroy(context.address);
        allocator.destroy(context);

        std.debug.print("Server error: {}\n", .{err});
    };
}

/// This server will be shutdown after response at once
fn runServer(context: *ServerContext) !void {
    // Since we chose port: 0, OS will pick a port for us
    const address = try std.net.Address.parseIp("127.0.0.1", 0);

    const tpe: u32 = posix.SOCK.STREAM;
    const protocol = posix.IPPROTO.TCP;
    const listener = try posix.socket(address.any.family, tpe, protocol);
    defer posix.close(listener);

    try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try posix.bind(listener, &address.any, address.getOsSockLen());

    // Get a actual address that OS picked above
    var actual_address: std.net.Address = undefined;
    var len: posix.socklen_t = @sizeOf(net.Address);
    try posix.getsockname(listener, &actual_address.any, &len);
    context.address.* = actual_address;

    try posix.listen(listener, 128);

    while (true) {
        const allocator = context.allocator;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var client_address: net.Address = undefined;
        var client_address_len: posix.socklen_t = @sizeOf(net.Address);

        const client_socket = posix.accept(listener, &client_address.any, &client_address_len, 0) catch |err| {
            std.debug.print("error accept: {}\n", .{err});
            return err;
        };
        defer posix.close(client_socket);

        var buf: [4096]u8 = undefined;
        var jsonStream = JsonStream{
            .buf = &buf,
            .start = 0,
            .pos = 0,
        };
        const request_message = try jsonStream.readMessage(client_socket);
        const request = try RequestObject.fromSlice(allocator, request_message);
        defer request.deinit(allocator);

        if (request.id) |id| {
            // echo request method
            var response = try ResponseObject.initOk(allocator, JsonRpcVersion.v2, id, std.json.Value{ .string = request.method });
            defer response.deinit(allocator);

            const responseJson = try response.toJson();
            try jsonStream.writeMessage(responseJson, client_socket);
        }

        // This is fine since this server is for testing purposes only.
        break;
    }
}
