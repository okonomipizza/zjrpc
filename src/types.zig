const std = @import("std");
const json = std.json;
const testing = std.testing;

const Allocator = std.mem.Allocator;

/// Version of JSON-RPC protocol
/// Must be exactly "2.0"
pub const JsonRpcVersion = enum {
    v2,

    pub fn fromString(version: []const u8) !JsonRpcVersion {
        if (std.mem.eql(u8, version, "2.0")) {
            return .v2;
        }
        return error.UnsupportedJsonRpcVersion;
    }

    pub fn toString(self: JsonRpcVersion) []const u8 {
        return switch (self) {
            .v2 => "2.0",
        };
    }
};

pub const RequestId = union(enum) {
    number: i64,
    string: []const u8,

    pub fn toJson(self: RequestId) json.Value {
        return switch (self) {
            .number => |id_int| json.Value{ .integer = id_int },
            .string => |id_str| json.Value{ .string = id_str },
        };
    }
};

pub const Params = union(enum) {
    array: json.Array,
    object: json.ObjectMap,

    pub fn toJson(self: Params) json.Value {
        return switch (self) {
            .array => |arr| json.Value{ .array = arr },
            .object => |obj| json.Value{ .object = obj },
        };
    }

    pub fn fromJsonArray(array: json.Array) Params {
        return .{ .array = array };
    }

    pub fn fromJsonObject(object: json.ObjectMap) Params {
        return .{ .object = object };
    }
};

pub const RequestObject = struct {
    /// Protocol Version
    jsonrpc: JsonRpcVersion,
    /// Name of the method to be invoked
    method: []const u8,
    /// Params holds the parameter value to be used during the invocation of the method
    params: ?Params,
    /// Request ID
    /// If null, it will be consumed as notification
    id: ?RequestId,
    arena: std.heap.ArenaAllocator,

    /// Creates and allocates a new RequestObject with its own arena allocator.
    /// Caller must call RequestObject.deinit() to free resources.
    pub fn init(alloc: Allocator, jsonrpc: JsonRpcVersion, method: []const u8, params: ?Params, id: ?RequestId) !*RequestObject {
        const req = try alloc.create(RequestObject);
        errdefer alloc.destroy(req);

        req.* = .{
            .jsonrpc = jsonrpc,
            .method = method,
            .params = params,
            .id = id,
            .arena = std.heap.ArenaAllocator.init(alloc),
        };
        return req;
    }

    pub fn deinit(s: *RequestObject, parent_alloc: Allocator) void {
        s.arena.deinit();
        parent_alloc.destroy(s);
    }

    /// Creates and allocates a new RequestObject with its own arena allocator.
    /// Caller must call RequestObject.deinit() to free resources.
    pub fn fromSlice(alloc: Allocator, jsonString: []const u8) !*RequestObject {
        const req = try alloc.create(RequestObject);
        errdefer alloc.destroy(req);

        req.arena = std.heap.ArenaAllocator.init(alloc);
        errdefer req.arena.deinit();

        const arena_alloc = req.arena.allocator();

        // No errdefer needed - arena cleanup handles it
        const parsedJson: json.Parsed(json.Value) = try json.parseFromSlice(json.Value, arena_alloc, jsonString, .{});

        const root = switch (parsedJson.value) {
            .object => |obj| obj,
            else => return error.NotARequestObject,
        };

        const jsonrpc_value = root.get("jsonrpc") orelse return error.MissingProtocolVersion;
        const jsonrpc = switch (jsonrpc_value) {
            .string => |str| str,
            else => return error.ProtocolVersionShouldBeString,
        };

        const method_value = root.get("method") orelse return error.MissingMethod;
        const method = switch (method_value) {
            .string => |str| str,
            else => return error.MethodShouldBeString,
        };

        const params: ?Params = blk: {
            const params_value = root.get("params") orelse break :blk null;
            switch (params_value) {
                .array => |arr| break :blk Params.fromJsonArray(arr),
                .object => |obj| break :blk Params.fromJsonObject(obj),
                else => return error.InvalidParams,
            }
        };

        const id: ?RequestId = blk: {
            const id_value = root.get("id") orelse break :blk null;
            switch (id_value) {
                .string => |str_id| break :blk RequestId{ .string = str_id },
                .integer => |int_id| break :blk RequestId{ .number = int_id },
                .null => break :blk null,
                else => return error.InvalidID,
            }
        };

        req.jsonrpc = try JsonRpcVersion.fromString(jsonrpc);
        req.method = method;
        req.params = params;
        req.id = id;
        return req;
    }

    pub fn toJson(self: *RequestObject) ![]const u8 {
        const allocator = self.arena.allocator();

        var json_object = json.ObjectMap.init(allocator);
        defer json_object.deinit();

        try json_object.put("jsonrpc", json.Value{ .string = self.jsonrpc.toString() });
        try json_object.put("method", json.Value{ .string = self.method });
        if (self.params) |params| {
            try json_object.put("params", params.toJson());
        }
        if (self.id) |id| {
            try json_object.put("id", id.toJson());
        }

        const json_val = json.Value{ .object = json_object };

        const str = try json.Stringify.valueAlloc(allocator, json_val, .{});

        return str;
    }
};

test "RequestObject.fromSlice" {
    const allocator = testing.allocator;

    const json_str =
        \\{"jsonrpc":"2.0","method":"subtract","params":{"minuend":42,"subtrahend":7},"id":1}
    ;

    var request = try RequestObject.fromSlice(allocator, json_str);
    defer request.deinit(allocator);

    try testing.expect(request.jsonrpc == .v2);
    try testing.expectEqualStrings("subtract", request.method);
    try testing.expectEqualDeep(RequestId{ .number = 1 }, request.id);

    try testing.expect(request.params != null);
    const params = request.params.?;
    try testing.expect(params == .object);

    const params_obj = params.object;
    const minuend = params_obj.get("minuend").?;
    const subtrahend = params_obj.get("subtrahend").?;

    try testing.expect(minuend == .integer);
    try testing.expect(subtrahend == .integer);
    try testing.expectEqual(@as(i64, 42), minuend.integer);
    try testing.expectEqual(@as(i64, 7), subtrahend.integer);
}

test "RequestObject.toJson" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const expected =
        \\{"jsonrpc":"2.0","method":"subtract","params":{"minuend":42,"subtrahend":7},"id":"1"}
    ;

    var params_object = json.ObjectMap.init(arena_alloc);
    try params_object.put("minuend", json.Value{ .integer = 42 });
    try params_object.put("subtrahend", json.Value{ .integer = 7 });

    const params = Params.fromJsonObject(params_object);

    var request = try RequestObject.init(allocator, JsonRpcVersion.v2, "subtract", params, RequestId{ .string = "1" });
    defer request.deinit(allocator);

    const actual = try request.toJson();

    try testing.expectEqualStrings(expected, actual);
}
