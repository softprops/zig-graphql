///! Runs a request against the GitHub GQL API
///! see [the GitHub GQL Explorer](https://docs.github.com/en/graphql/overview/explorer) to learn more about the GitHub schema
const std = @import("std");
const gql = @import("graphql");

pub const std_options: std.Options = .{
    .log_level = .info, // the default is .debug
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const authz = if (std.posix.getenv("GH_TOKEN")) |pat| blk: {
        var buf: [400]u8 = undefined;
        break :blk try std.fmt.bufPrint(
            &buf,
            "bearer {s}",
            .{pat},
        );
    } else {
        std.log.info("Required GH_TOKEN env var containing a GitHub API token - https://github.com/settings/tokens", .{});
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

    const result = github.send(
        .{
            .query =
            \\query test {
            \\  search(first: 100, type: REPOSITORY, query: "topic:zig") {
            \\      repositoryCount
            \\  }
            \\}
            ,
        },
        // 👇 struct representing returned data, this maybe be an adhoc or named struct
        //    you want this to line up with the shape of your query
        struct {
            search: struct {
                repositoryCount: usize,
            },
        },
    );

    // handle success and error
    if (result) |resp| {
        defer resp.deinit();
        switch (resp.value.result()) {
            .data => |data| std.debug.print(
                "zig repo count {any}\n",
                .{data.search.repositoryCount},
            ),
            .errors => |errors| {
                for (errors) |err| {
                    std.debug.print("Error: {s}", .{err.message});
                    if (err.path) |p| {
                        const path = try std.mem.join(allocator, "/", p);
                        defer allocator.free(path);
                        std.debug.print(" @ {s}", .{path});
                    }
                }
            },
        }
    } else |err| {
        std.log.err(
            "Request failed with {any}",
            .{err},
        );
    }
}
