/// A very basic general purpose GraphQL HTTP client
const std = @import("std");

pub const Endpoint = union(enum) {
    url: []const u8,
    uri: std.Uri,

    fn toUri(self: @This()) std.Uri.ParseError!std.Uri {
        return switch (self) {
            .url => |u| try std.Uri.parse(u),
            .uri => |u| u,
        };
    }
};

/// Represents a standard GraphQL request
///
/// see also these [GraphQL docs](https://graphql.org/learn/serving-over-http/#post-request)
pub const Request = struct {
    query: []const u8,
    operationName: ?[]const u8 = null,
};

pub const Location = struct {
    line: usize,
    column: usize,
};

/// Represents a standard GraphQL response error
///
/// See the [GraphQL docs](https://spec.graphql.org/October2021/#sec-Errors.Error-result-format) for more information
pub const Error = struct {
    message: []const u8,
    path: ?[][]const u8 = null,
    locations: ?[]Location = null,
};

/// Represents a standard GraphQL response which may contain data or errors. Use the `result` method to dereference this for the common usecase
/// of one or the other but not both
///
/// See the [GraphQL docs](https://graphql.org/learn/serving-over-http/#response) for more information
fn Response(comptime T: type) type {
    return struct {
        errors: ?[]Error = null,
        data: ?T = null,

        /// a union of data or errors
        const Result = union(enum) { data: T, errors: []Error };

        /// simplifies the ease of processing the presence and/or absence of data or errors
        /// in a unified type. This method assumes the response contains one or the other.
        pub fn result(self: @This()) Result {
            if (self.data) |data| {
                return .{ .data = data };
            } else if (self.errors) |errors| {
                return .{ .errors = errors };
            } else {
                unreachable;
            }
        }
    };
}

/// Client options
pub const Options = struct {
    /// HTTP url for graphql endpoint
    endpoint: Endpoint,
    /// HTTP authorization header contents
    authorization: ?[]const u8,
};

/// Possible request errors
const RequestError = error{
    NotAuthorized,
    Forbidden,
    ServerError,
    Http,
    Json,
    Throttled,
};

/// A type that expresses the caller's ownership responsiblity to deinitailize the data.
pub fn Owned(comptime T: type) type {
    return struct {
        value: T,
        arena: *std.heap.ArenaAllocator,

        const Self = @This();

        fn fromJson(parsed: std.json.Parsed(T)) Self {
            return .{
                .arena = parsed.arena,
                .value = parsed.value,
            };
        }

        pub fn deinit(self: Self) void {
            const arena = self.arena;
            const allocator = arena.child_allocator;
            arena.deinit();
            allocator.destroy(arena);
        }
    };
}

/// A simple GraphQL HTTP client
pub const Client = struct {
    httpClient: std.http.Client,
    allocator: std.mem.Allocator,
    options: Options,
    const Self = @This();

    /// Initializes a new GQL Client. Be sure to call `deinit` when finished
    /// using this instance
    pub fn init(
        allocator: std.mem.Allocator,
        options: Options,
    ) std.Uri.ParseError!Self {
        // validate that Uri is validate as early as possible
        _ = try options.endpoint.toUri();
        return .{
            .httpClient = std.http.Client{ .allocator = allocator },
            .allocator = allocator,
            .options = options,
        };
    }

    /// Call this method to deallocate resources
    pub fn deinit(self: *Self) void {
        self.httpClient.deinit();
    }

    /// Sends a GraphQL Request to a server
    ///
    /// Callers are expected to call `deinit()` on the Owned type returned to free memory.
    pub fn send(
        self: *Self,
        request: Request,
        comptime T: type,
    ) RequestError!Owned(Response(T)) {
        var headers = std.http.Headers.init(self.allocator);
        defer headers.deinit();
        headers.append("Content-Type", "application/json") catch return error.Http;
        if (self.options.authorization) |authz| {
            headers.append("Authorization", authz) catch return error.Http;
        }
        var req = self.httpClient.request(
            .POST,
            // endpoint is validated on client init
            self.options.endpoint.toUri() catch unreachable,
            headers,
            .{},
        ) catch return error.Http;
        defer req.deinit();
        req.transfer_encoding = .chunked;
        req.start() catch return error.Http;
        serializeRequest(request, req.writer()) catch return error.Json;
        req.finish() catch return error.Http;
        req.wait() catch return error.Http;
        switch (req.response.status.class()) {
            // client errors
            .client_error => switch (req.response.status) {
                .unauthorized => return error.NotAuthorized,
                .forbidden => return error.Forbidden,
                else => return error.Http,
            },
            // handle server errors
            .server_error => return error.ServerError,
            // handle "success"
            else => {
                std.log.debug("response {any}", .{req.response.status});
                const body = req.reader().readAllAlloc(
                    self.allocator,
                    8192 * 2 * 2, // note: optimistic arb choice of buffer size
                ) catch unreachable;
                defer self.allocator.free(body);
                const parsed = parseResponse(self.allocator, body, T) catch return error.Json;
                return Owned(Response(T)).fromJson(parsed);
            },
        }
    }
};

fn serializeRequest(request: Request, writer: anytype) @TypeOf(writer).Error!void {
    try std.json.stringify(
        request,
        .{ .emit_null_optional_fields = false },
        writer,
    );
}

fn parseResponse(
    allocator: std.mem.Allocator,
    body: []const u8,
    comptime T: type,
) std.json.ParseError(std.json.Scanner)!std.json.Parsed(Response(T)) {
    std.log.debug("parsing body {s}\n", .{body});
    return try std.json.parseFromSlice(
        Response(T),
        allocator,
        body,
        .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always, // nested structures are known to segfault with the default
        },
    );
}

test "serialize request" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const tests = [_]struct {
        request: Request,
        expect: []const u8,
    }{
        .{
            .request = .{
                .query =
                \\ {
                \\   foo
                \\ }
                ,
            },
            .expect =
            \\{"query":" {\n   foo\n }"}
            ,
        },
        .{
            .request = .{
                .query =
                \\ {
                \\   foo
                \\ }
                ,
                .operationName = "foo",
            },
            .expect =
            \\{"query":" {\n   foo\n }","operationName":"foo"}
            ,
        },
    };
    for (tests) |t| {
        defer fbs.reset();
        try serializeRequest(t.request, fbs.writer());
        try std.testing.expectEqualStrings(t.expect, fbs.getWritten());
    }
}

test "parse response" {
    var allocator = std.testing.allocator;
    const T = struct {
        foo: []const u8,
    };
    var path = [_][]const u8{
        "foo",
        "bar",
    };
    var err = Error{
        .message = "err",
        .path = &path,
    };
    var errors = [_]Error{
        err,
    };
    const tests = [_]struct {
        body: []const u8,
        result: anyerror!Response(T),
    }{
        .{
            .body =
            \\{
            \\  "data": {
            \\    "foo": "success"
            \\  }
            \\}
            ,
            .result = .{
                .data = .{
                    .foo = "success",
                },
            },
        },
        .{
            .body =
            \\{
            \\  "errors": [{
            \\    "message": "err",
            \\    "path": ["foo","bar"]
            \\  }]
            \\}
            ,
            .result = .{
                .errors = &errors,
            },
        },
    };

    for (tests) |t| {
        const result = try parseResponse(allocator, t.body, T);
        defer result.deinit();
        try std.testing.expectEqualDeep(t.result, result.value);
    }
}

test "response" {
    var err = Error{
        .message = "err",
    };
    var errors = [_]Error{
        err,
    };
    const tests = [_]struct {
        response: Response(u32),
        result: Response(u32).Result,
    }{
        .{
            .response = .{ .data = 42 },
            .result = .{ .data = 42 },
        },
        .{
            .response = .{ .errors = &errors },
            .result = .{ .errors = &errors },
        },
    };

    for (tests) |t| {
        try std.testing.expectEqualDeep(t.result, t.response.result());
    }
}
