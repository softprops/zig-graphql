<h1 align="center">
    zig graphql
</h1>

<div align="center">
    A very basic GraphQL HTTP client for zig
</div>

---

[![ci](https://github.com/softprops/zig-graphql/actions/workflows/ci.yml/badge.svg)](https://github.com/softprops/zig-graphql/actions/workflows/ci.yml) ![License Info](https://img.shields.io/github/license/softprops/zig-graphql) ![Releases](https://img.shields.io/github/v/release/softprops/zig-graphql) [![Zig Support](https://img.shields.io/badge/zig-0.12.0-black?logo=zig)](https://ziglang.org/documentation/0.12.0/)

## examples

```zig
const std = @import("std");
const graphql = @import("graphql");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const authz = if (std.os.getenv("GH_TOKEN")) |pat| blk: {
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

    // 👇 constructing a client
    var github = try graphql.Client.init(
        allocator,
        .{
            .endpoint = .{ .url = "https://api.github.com/graphql" },
            .authorization = authz,
        },
    );
    defer github.deinit();

    // 👇 sending a request
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

    // 👇 handle success and error
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
```

## 📼 installing

Create a new exec project with `zig init-exe`. Copy the echo handler example above into `src/main.zig`

Create a `build.zig.zon` file to declare a dependency

> .zon short for "zig object notation" files are essentially zig structs. `build.zig.zon` is zigs native package manager convention for where to declare dependencies

```zig
.{
    .name = "my-app",
    .version = "0.1.0",
    .dependencies = .{
        // 👇 declare dep properties
        .graphql = .{
            // 👇 uri to download
            .url = "https://github.com/softprops/zig-graphql/archive/refs/tags/v0.2.0.tar.gz",
            // 👇 hash verification
            .hash = "{current-hash-here}",
        },
    },
    .paths = .{""},
}
```

> the hash below may vary. you can also depend any tag with `https://github.com/softprops/zig-graphql/archive/refs/tags/v{version}.tar.gz` or current main with `https://github.com/softprops/zig-graphql/archive/refs/heads/main/main.tar.gz`. to resolve a hash omit it and let zig tell you the expected value.

Add the following in your `build.zig` file

```diff
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});
+    // 👇 de-reference graphql dep from build.zig.zon
+    const graphql = b.dependency("graphql", .{
+        .target = target,
+        .optimize = optimize,
+    }).module("graphql");
    var exe = b.addExecutable(.{
        .name = "your-exe",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
+    // 👇 add the graphql module to executable
+    exe.root_module.addImport("graphql", graphql);

    b.installArtifact(exe);
}
```

## 🥹 for budding ziglings

Does this look interesting but you're new to zig and feel left out? No problem, zig is young so most us of our new are as well. Here are some resources to help get you up to speed on zig

- [the official zig website](https://ziglang.org/)
- [zig's one-page language documentation](https://ziglang.org/documentation/0.11.0/)
- [ziglearn](https://ziglearn.org/)
- [ziglings exercises](https://github.com/ratfactor/ziglings)

\- softprops 2024
