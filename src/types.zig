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
    pub fn init(allocator: Allocator, jsonrpc: JsonRpcVersion, method: []const u8, params: ?Params, id: ?RequestId) !*RequestObject {
        const req = try allocator.create(RequestObject);
        errdefer allocator.destroy(req);

        req.* = .{
            .jsonrpc = jsonrpc,
            .method = method,
            .params = params,
            .id = id,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
        return req;
    }

    pub fn deinit(self: *RequestObject, allocator: Allocator) void {
        self.arena.deinit();
        allocator.destroy(self);
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

/// A number that indicates the error type that occured.
pub const ErrorCode = union(enum) {
    parseError,
    invalidRequest,
    methodNotFound,
    invalidParams,
    internalError,
    /// Reserved for implementation-defined server-errors.
    serverError: i64,

    /// Returns the value of the error code.
    pub fn value(self: ErrorCode) i64 {
        return switch (self) {
            .parseError => -32700,
            .invalidRequest => -32600,
            .methodNotFound => -32601,
            .invalidParams => -32602,
            .internalError => -32603,
            .serverError => |code| code,
        };
    }

    /// Returns the ErrorCode from integer.
    pub fn fromValue(code: i64) !ErrorCode {
        return switch (code) {
            -32700 => .parseError,
            -32600 => .invalidRequest,
            -32601 => .methodNotFound,
            -32602 => .invalidParams,
            -32603 => .internalError,
            else => {
                if (-32099 <= code and code <= -32000) {
                    // Valid server error range.
                    return .{ .serverError = @intCast(code) };
                } else if (-32768 <= code and code < -32000) {
                    // Reserved range for future use.
                    return error.ReservedErrorCode;
                } else {
                    // Out of reserved range.
                    return error.InvalidErrorCode;
                }
            },
        };
    }
};

pub const ErrorObject = struct {
    /// Integer indicates the error thar occurred
    code: ErrorCode,
    /// Short description about the error
    message: []const u8,
    /// We can attach additional information about the errors
    data: ?json.Value = null,

    pub fn fromJsonObject(json_value: json.Value) !ErrorObject {
        switch (json_value) {
            .object => |obj| {
                const code: ErrorCode = blk: {
                    const code_value = obj.get("code") orelse return error.MissingErrorCode;
                    switch (code_value) {
                        .integer => |code| break :blk try ErrorCode.fromValue(code),
                        else => return error.InvalidErrorCode,
                    }
                };

                const message = blk: {
                    const message_value = obj.get("message") orelse return error.MissingErrorMessage;
                    switch (message_value) {
                        .string => |msg| break :blk msg,
                        else => return error.InvalidErrorMessage,
                    }
                };

                const data: ?json.Value = obj.get("data");

                return .{
                    .code = code,
                    .message = message,
                    .data = data,
                };
            },
            else => return error.InvalidErrorObject,
        }
    }
};

pub const ResponseObject = union(enum) {
    ok: struct {
        jsonrpc: JsonRpcVersion,
        id: RequestId,
        result: json.Value,
        arena: std.heap.ArenaAllocator,
    },
    err: struct {
        jsonrpc: JsonRpcVersion,
        id: ?RequestId,
        @"error": ErrorObject,
        arena: std.heap.ArenaAllocator,
    },

    pub fn initOk(allocator: Allocator, jsonrpc: JsonRpcVersion, id: RequestId, result: json.Value) !*ResponseObject {
        const response = try allocator.create(ResponseObject);
        errdefer allocator.destroy(response);

        response.* = ResponseObject{
            .ok = .{
                .jsonrpc = jsonrpc,
                .id = id,
                .result = result,
                .arena = std.heap.ArenaAllocator.init(allocator),
            },
        };

        return response;
    }

    pub fn initErr(allocator: Allocator, jsonrpc: JsonRpcVersion, id: ?RequestId, error_obj: ErrorObject) !*ResponseObject {
        const response = try allocator.create(ResponseObject);
        errdefer allocator.destroy(response);

        response.* = ResponseObject{
            .err = .{
                .jsonrpc = jsonrpc,
                .id = id,
                .@"error" = error_obj,
                .arena = std.heap.ArenaAllocator.init(allocator),
            },
        };

        return response;
    }

    pub fn fromSlice(allocator: Allocator, json_string: []const u8) !*ResponseObject {
        const response = try allocator.create(ResponseObject);
        errdefer allocator.destroy(response);

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const parsed_json: json.Parsed(json.Value) = json.parseFromSlice(json.Value, arena.allocator(), json_string, .{}) catch |err| {
            arena.deinit();
            allocator.destroy(response);
            return err;
        };

        const root = switch (parsed_json.value) {
            .object => |obj| obj,
            else => {
                arena.deinit();
                allocator.destroy(response);
                return error.NotARequestObject;
            },
        };

        const jsonrpc_value = root.get("jsonrpc") orelse return error.MissingProtocolVersion;
        const jsonrpc = switch (jsonrpc_value) {
            .string => |str| try JsonRpcVersion.fromString(str),
            else => {
                arena.deinit();
                allocator.destroy(response);
                return error.ProtocolVersionShouldBeString;
            },
        };

        if (root.get("error")) |error_value| {
            // This is an error response
            const id: ?RequestId = blk: {
                const id_value = root.get("id") orelse break :blk null;
                switch (id_value) {
                    .string => |str_id| break :blk RequestId{ .string = str_id },
                    .integer => |int_id| break :blk RequestId{ .number = int_id },
                    .null => break :blk null,
                    else => {
                        arena.deinit();
                        allocator.destroy(response);
                        return error.InvalidID;
                    },
                }
            };

            const error_object = try ErrorObject.fromJsonObject(error_value);

            response.* = ResponseObject{ .err = .{
                .jsonrpc = jsonrpc,
                .id = id,
                .@"error" = error_object,
                .arena = arena,
            } };
        } else {
            // This is an success response
            const id: RequestId = blk: {
                const id_value = root.get("id") orelse return error.MissingID;
                switch (id_value) {
                    .string => |str_id| break :blk RequestId{ .string = str_id },
                    .integer => |int_id| break :blk RequestId{ .number = int_id },
                    else => return error.InvalidID,
                }
            };
            const result: json.Value = root.get("result") orelse return error.MissingResult;
            response.* = ResponseObject{ .ok = .{
                .jsonrpc = jsonrpc,
                .id = id,
                .result = result,
                .arena = arena,
            } };
        }
        return response;
    }

    pub fn toJson(self: *ResponseObject) ![]const u8 {
        const allocator = blk: {
            switch (self.*) {
                .ok => break :blk self.ok.arena.allocator(),
                .err => break :blk self.err.arena.allocator(),
            }
        };

        var json_object = json.ObjectMap.init(allocator);
        defer json_object.deinit();

        switch (self.*) {
            .ok => |ok| {
                try json_object.put("jsonrpc", json.Value{ .string = ok.jsonrpc.toString() });
                try json_object.put("id", ok.id.toJson());
                try json_object.put("result", ok.result);
            },
            .err => |err| {
                try json_object.put("jsonrpc", json.Value{ .string = err.jsonrpc.toString() });
                if (err.id) |id| {
                    try json_object.put("id", id.toJson());
                }

                // Create error object JSON
                var error_obj = json.ObjectMap.init(allocator);

                try error_obj.put("code", json.Value{ .integer = err.@"error".code.value() });
                try error_obj.put("message", json.Value{ .string = err.@"error".message });
                if (err.@"error".data) |data| {
                    try error_obj.put("data", data);
                }
                try json_object.put("error", json.Value{ .object = error_obj });
            },
        }
        const json_val = json.Value{ .object = json_object };

        const str = try json.Stringify.valueAlloc(allocator, json_val, .{});

        return str;
    }

    pub fn deinit(self: *ResponseObject, parent_alloc: Allocator) void {
        switch (self.*) {
            .ok => |ok| ok.arena.deinit(),
            .err => |err| err.arena.deinit(),
        }
        parent_alloc.destroy(self);
    }
};

// /// MaybeBatch only accepts RequstObject or ResponseObject
// fn isJsonRpcObject(comptime T: type) bool {
//     if (!@hasDecl(T, "fromSlice")) return false;
//     if (!@hasDecl(T, "deinit")) return false;
//
//     const fromSlice = @field(T, "fromSlice");
//     const fromSlice_info = @typeInfo(@TypeOf(fromSlice));
//     if (fromSlice_info != .@"fn") return false;
//
//     const type_info = @typeInfo(T);
//     switch (type_info) {
//         .@"struct" => {
//             // RequestObject
//             if (@hasField(T, "jsonrpc") and @hasField(T, "method")) return true;
//         },
//         .@"union" => {
//             // ResponseObject
//             if (@hasField(T, "ok") or @hasField(T, "err")) return true;
//         },
//         else => return false,
//     }
//
//     return false;
// }

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

test "ResponseObject.fromSlice - success response" {
    const allocator = testing.allocator;

    const json_str =
        \\{"jsonrpc":"2.0","id":1,"result":"success"}
    ;

    const response = try ResponseObject.fromSlice(allocator, json_str);
    defer response.deinit(allocator);

    try testing.expect(response.* == .ok);
    const ok = response.ok;
    try testing.expect(ok.jsonrpc == .v2);
    try testing.expectEqualDeep(RequestId{ .number = 1 }, ok.id);

    const result = ok.result;
    try testing.expect(result == .string);
    try testing.expectEqualStrings("success", result.string);
}

test "ResponseObject.fromSlice - success response with null result" {
    const allocator = testing.allocator;

    const json_str =
        \\{"jsonrpc":"2.0","id":"test","result":null}
    ;

    const response = try ResponseObject.fromSlice(allocator, json_str);
    defer response.deinit(allocator);

    try testing.expect(response.* == .ok);
    const ok = response.ok;
    try testing.expect(ok.jsonrpc == .v2);
    try testing.expectEqualDeep(RequestId{ .string = "test" }, ok.id);

    const result = ok.result;
    try testing.expect(result == .null);
}

test "ResponseObject.fromSlice - success response with object result" {
    const allocator = testing.allocator;

    const json_str =
        \\{"jsonrpc":"2.0","id":42,"result":{"value":123,"message":"done"}}
    ;

    const response = try ResponseObject.fromSlice(allocator, json_str);
    defer response.deinit(allocator);

    try testing.expect(response.* == .ok);
    const ok = response.ok;
    try testing.expect(ok.jsonrpc == .v2);
    try testing.expectEqualDeep(RequestId{ .number = 42 }, ok.id);

    const result = ok.result;
    try testing.expect(result == .object);

    const result_obj = result.object;
    const value = result_obj.get("value").?;
    const message = result_obj.get("message").?;

    try testing.expect(value == .integer);
    try testing.expect(message == .string);
    try testing.expectEqual(@as(i64, 123), value.integer);
    try testing.expectEqualStrings("done", message.string);
}

test "ResponseObject.fromSlice - error response with string ID" {
    const allocator = testing.allocator;

    const json_str =
        \\{"jsonrpc":"2.0","id":"req-1","error":{"code":-32601,"message":"Method not found"}}
    ;

    const response = try ResponseObject.fromSlice(allocator, json_str);
    defer response.deinit(allocator);

    try testing.expect(response.* == .err);
    const err = response.err;
    try testing.expect(err.jsonrpc == .v2);
    try testing.expect(err.id != null);
    try testing.expectEqualDeep(RequestId{ .string = "req-1" }, err.id.?);

    const error_obj = err.@"error";
    try testing.expect(error_obj.code == .methodNotFound);
    try testing.expectEqualStrings("Method not found", error_obj.message);
    try testing.expect(error_obj.data == null);
}

test "ResponseObject.fromSlice - error response with null ID" {
    const allocator = testing.allocator;

    const json_str =
        \\{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}
    ;

    const response = try ResponseObject.fromSlice(allocator, json_str);
    defer response.deinit(allocator);

    try testing.expect(response.* == .err);
    const err = response.err;
    try testing.expect(err.jsonrpc == .v2);
    try testing.expect(err.id == null);

    const error_obj = err.@"error";
    try testing.expect(error_obj.code == .parseError);
    try testing.expectEqualStrings("Parse error", error_obj.message);
    try testing.expect(error_obj.data == null);
}

test "ResponseObject.toJson - success response" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const expected =
        \\{"jsonrpc":"2.0","id":1,"result":"success"}
    ;

    var response = try ResponseObject.initOk(allocator, JsonRpcVersion.v2, RequestId{ .number = 1 }, json.Value{ .string = "success" });
    defer response.deinit(allocator);

    const actual = try response.toJson();

    try testing.expectEqualStrings(expected, actual);
}

test "ResponseObject.toJson - error response" {
    const allocator = testing.allocator;
    const arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const error_obj = ErrorObject{
        .code = ErrorCode.methodNotFound,
        .message = "Method not found",
        .data = null,
    };

    var response = try ResponseObject.initErr(allocator, JsonRpcVersion.v2, RequestId{ .number = 1 }, error_obj);
    defer response.deinit(allocator);

    const expected =
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}
    ;

    const actual = try response.toJson();

    try testing.expectEqualStrings(expected, actual);
}
