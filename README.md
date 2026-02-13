# zjrpc

A minimal JSON-RPC 2.0 over TCP library for Zig.

Messages are framed with a 4-byte little-endian length prefix followed by a JSON payload.

```
[4-byte LE length][JSON payload]
```

### Request-Response (`call`)

Send a request and wait for a response.

```zig
const std = @import("std");
const zjrpc = @import("zjrpc");

const RpcClient     = zjrpc.RpcClient;
const RequestObject = zjrpc.RequestObject;
const ResponseObject = zjrpc.ResponseObject;
const JsonRpcVersion = zjrpc.JsonRpcVersion;
const RequestId     = zjrpc.RequestId;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const address = try std.net.Address.parseIp("127.0.0.1", 9000);

    var client = try RpcClient.init(allocator, 4096, address);
    defer client.deinit();

    var request = try RequestObject.init(
        allocator,
        JsonRpcVersion.v2,
        "echo",
        null,
        RequestId{ .number = 1 },
    );
    defer request.deinit(allocator);

    const response = try client.call(allocator, &request);
    defer response.deinit(allocator);

    std.debug.print("result: {s}\n", .{response.ok.result.string});
}
```

### Notification (`cast`)

Send a request without waiting for a response (fire-and-forget).

Suitable for JSON-RPC notifications where `id` is omitted.

```zig
const request = try RequestObject.init(
    allocator,
    JsonRpcVersion.v2,
    "notify",
    null,
    null, // no id = notification
);
defer request.deinit(allocator);

try client.cast(&request);
```

### Server implementation
See spawn_server_thread() in the root.zig.

