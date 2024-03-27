const std = @import("std");
const gql = @import("gql");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var authz = if (std.os.getenv("GH_TOKEN")) |pat| blk: {
        var buf: [400]u8 = undefined;
        break :blk try std.fmt.bufPrint(
            &buf,
            "bearer {s}",
            .{pat},
        );
    } else {
        std.log.err("An GH_TOKEN env var containing a GitHub API token is required", .{});
        return;
    };

    var github = try gql.Client.init(
        allocator,
        .{
            .endpoint = .{ .url = "https://api.github.com/graphql" },
            .authorization = authz,
        },
    );
    defer github.deinit();

    var result = github.send(
        .{
            .query =
            \\query test {
            \\  search(first: 100, type: REPOSITORY, query: "topic:zig") {
            \\      repositoryCounta
            \\  }
            \\}
            ,
        },
        struct {
            search: struct {
                repositoryCount: usize,
            },
        },
    );

    // handle success and error
    if (result) |resp| {
        defer resp.deinit();
        std.debug.print(
            "resp {any}",
            .{
                switch (resp.value.result()) {
                    .data => |data| std.debug.print("{any}", .{data}),
                    .errors => |errors| std.debug.print("{any}", .{errors}),
                },
            },
        );
    } else |err| {
        std.log.err(
            "Request failed with error {any}",
            .{err},
        );
    }
}
