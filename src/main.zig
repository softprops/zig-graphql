/// A very basic general purpose GraphQL HTTP client
const std = @import("std");
const testing = std.testing;

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
    // variables: ?(???)
};

pub const Error = struct {
    message: []const u8,
    code: []const u8,
};

/// Represents a standard GraphQL response which may contain data or errors. Use the `result` method to dereference this for the common usecase
/// of one or the other but not both
///
/// see also these [GraphQL docs](https://graphql.org/learn/serving-over-http/#response)
fn Response(comptime T: type) type {
    return struct {
        errors: ?[]const Error = null,
        data: ?T = null,

        /// a union of data or errors
        const Result = union(enum) { data: T, errors: []const Error };

        /// simplifies the ease of processing the presence and/or absence of data or errors
        /// in a unified type. this method assumes the response contains one or the other.
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
    ServerError,
    Http,
    Json,
    Throttled,
};

/// A simpel GraphQL HTTP client
pub const Client = struct {
    httpClient: std.http.Client,
    allocator: std.mem.Allocator,
    options: Options,
    const Self = @This();

    /// Initializes a new GQL Client. Be sure to call `deinit` when finished
    /// using this instance
    pub fn init(allocator: std.mem.Allocator, options: Options) std.Uri.ParseError!Self {
        // validate that Uri is validate as early as possible
        _ = try options.endpoint.toUri();
        return .{
            .httpClient = std.http.Client{ .allocator = allocator },
            .allocator = allocator,
            .options = options,
        };
    }

    /// Call this method to dealocate resources
    pub fn deinit(self: *Self) void {
        self.httpClient.deinit();
    }

    /// Sends a GraphQL Request to a server
    pub fn send(
        self: *Self,
        request: Request,
        comptime T: type,
    ) RequestError!std.json.Parsed(Response(T)) {
        var headers = std.http.Headers.init(self.allocator);
        defer headers.deinit();
        headers.append("Content-Type", "application/json") catch return error.Http;
        if (self.options.authorization) |authz| {
            headers.append("Authorization", authz) catch return error.Http;
        }
        var req = self.httpClient.request(
            .POST,
            self.options.endpoint.toUri() catch unreachable,
            headers,
            .{},
        ) catch return error.Http;
        defer req.deinit();
        req.transfer_encoding = .chunked;
        req.start() catch return error.Http;
        std.json.stringify(
            request,
            .{ .emit_null_optional_fields = false },
            req.writer(),
        ) catch return error.Json;
        req.finish() catch return error.Http;
        req.wait() catch return error.Http;

        switch (req.response.status.class()) {
            // client errors
            .client_error => switch (req.response.status) {
                .unauthorized => return error.NotAuthorized,
                else => return error.Http,
            },
            // handle server errors
            .server_error => return error.ServerError,
            // handle "success"
            else => {
                std.log.debug("response {any}", .{req.response.status});
                const body = req.reader().readAllAlloc(
                    self.allocator,
                    8192 * 2 * 2,
                ) catch unreachable;
                defer self.allocator.free(body);
                return parseResponse(self.allocator, body, T) catch return error.Json;
            },
        }
    }
};

fn parseResponse(
    allocator: std.mem.Allocator,
    body: []const u8,
    comptime T: type,
) !std.json.Parsed(Response(T)) {
    const parsed = try std.json.parseFromSlice(
        Response(T),
        allocator,
        body,
        .{
            .ignore_unknown_fields = true,
        },
    );
    std.debug.print("parsed {any}\n", .{parsed.value});
    return parsed;
}

test "parse response" {
    var allocator = std.testing.allocator;
    const T = struct {
        foo: []const u8,
    };
    // for runtime inline slice below
    var idx: usize = 0;

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
            \\    "code": "e"
            \\  }]
            \\}
            ,
            .result = .{
                .errors = ([_]Error{
                    Error{
                        .message = "err",
                        .code = "e",
                    },
                })[idx..],
            },
        },
    };

    for (tests) |t| {
        const result = try parseResponse(allocator, t.body, T);
        defer result.deinit();
        try std.testing.expectEqualDeep(t.result, result.value);
    }
}
