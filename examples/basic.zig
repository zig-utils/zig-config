const std = @import("std");
const zig_config = @import("zig-config");

// Define your configuration structure with type safety!
const AppConfig = struct {
    app_name: []const u8 = "My Application",
    port: u16 = 8080,
    debug: bool = false,
    max_connections: u32 = 100,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load configuration with full type safety
    var config = try zig_config.loadConfig(AppConfig, allocator, .{
        .name = "example",
        .env_prefix = "EXAMPLE",
    });
    defer config.deinit(allocator);

    // Display configuration source
    std.debug.print("Configuration loaded from: {s}\n", .{@tagName(config.source)});
    std.debug.print("Sources used ({d}):\n", .{config.sources.len});
    for (config.sources) |source| {
        std.debug.print("  - {s} (priority: {d})\n", .{ @tagName(source.source), source.priority });
    }
    std.debug.print("\n", .{});

    // Access configuration with full type safety - no runtime type checking!
    std.debug.print("Configuration values:\n", .{});
    std.debug.print("  app_name: {s}\n", .{config.value.app_name});
    std.debug.print("  port: {d}\n", .{config.value.port});
    std.debug.print("  debug: {}\n", .{config.value.debug});
    std.debug.print("  max_connections: {d}\n", .{config.value.max_connections});

    std.debug.print("\nTry setting environment variables:\n", .{});
    std.debug.print("  export EXAMPLE_PORT=3000\n", .{});
    std.debug.print("  export EXAMPLE_DEBUG=true\n", .{});
    std.debug.print("  export EXAMPLE_MAX_CONNECTIONS=200\n", .{});
}
