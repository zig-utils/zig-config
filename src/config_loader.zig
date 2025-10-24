const std = @import("std");
const types = @import("types.zig");
const errors = @import("errors.zig");
const FileLoader = @import("services/file_loader.zig").FileLoader;
const EnvProcessor = @import("services/env_processor.zig").EnvProcessor;
const merge = @import("merge.zig");
const utils = @import("utils.zig");

/// Configuration loader orchestrator
pub const ConfigLoader = struct {
    file_loader: FileLoader,
    env_processor: EnvProcessor,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !ConfigLoader {
        return ConfigLoader{
            .file_loader = FileLoader.init(allocator),
            .env_processor = EnvProcessor.init(allocator),
            .allocator = allocator,
        };
    }

    /// Load configuration with multi-source fallback
    pub fn load(
        self: *ConfigLoader,
        options: types.LoadOptions,
    ) !types.ConfigResult {
        var sources = try std.ArrayList(types.SourceInfo).initCapacity(self.allocator, 4);
        defer sources.deinit(self.allocator);

        // Determine CWD - allocate if not provided
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_from_fs = if (options.cwd == null) blk: {
            const path = try std.fs.cwd().realpath(".", &cwd_buf);
            break :blk try self.allocator.dupe(u8, path);
        } else null;
        defer if (cwd_from_fs) |path| self.allocator.free(path);

        const cwd = options.cwd orelse cwd_from_fs.?;

        var final_config: ?std.json.Value = null;
        var primary_source: types.ConfigSource = .defaults;

        // Try loading from local file
        if (try self.loadFromFile(options.name, cwd)) |config| {
            final_config = config;
            primary_source = .file_local;
            try sources.append(self.allocator, types.SourceInfo{
                .source = .file_local,
                .path = null,
                .priority = 3,
            });
        }

        // Try loading from home directory
        if (final_config == null) {
            if (try self.loadFromHome(options.name)) |config| {
                final_config = config;
                primary_source = .file_home;
                try sources.append(self.allocator, types.SourceInfo{
                    .source = .file_home,
                    .path = null,
                    .priority = 2,
                });
            }
        }

        // Apply defaults if no file found
        if (final_config == null and options.defaults != null) {
            final_config = try utils.cloneJsonValue(self.allocator, options.defaults.?);
            primary_source = .defaults;
            try sources.append(self.allocator, types.SourceInfo{
                .source = .defaults,
                .path = null,
                .priority = 0,
            });
        }

        // If still no config, create empty object
        if (final_config == null) {
            final_config = .{ .object = std.json.ObjectMap.init(self.allocator) };
        }

        // Apply environment variables
        const env_prefix = options.env_prefix orelse options.name;
        const with_env = try self.env_processor.applyEnvVars(final_config.?, env_prefix);

        // Check if env vars made changes
        if (try self.configsAreDifferent(final_config.?, with_env)) {
            try sources.append(self.allocator, types.SourceInfo{
                .source = .env_vars,
                .path = null,
                .priority = 1,
            });
        }

        return types.ConfigResult{
            .config = with_env,
            .source = primary_source,
            .sources = try sources.toOwnedSlice(self.allocator),
            .loaded_at = std.time.timestamp(),
            .allocator = self.allocator,
        };
    }

    fn loadFromFile(self: *ConfigLoader, name: []const u8, cwd: []const u8) !?std.json.Value {
        const path = try self.file_loader.findConfigFile(name, cwd) orelse return null;
        defer self.allocator.free(path);

        return try self.file_loader.loadConfigFile(path);
    }

    fn loadFromHome(self: *ConfigLoader, name: []const u8) !?std.json.Value {
        const home = std.posix.getenv("HOME") orelse return null;

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const config_dir = try std.fmt.bufPrint(&buf, "{s}/.config", .{home});

        const path = try self.file_loader.findConfigFile(name, config_dir) orelse return null;
        defer self.allocator.free(path);

        return try self.file_loader.loadConfigFile(path);
    }

    fn configsAreDifferent(self: *ConfigLoader, a: std.json.Value, b: std.json.Value) !bool {
        _ = self;
        // Use deep equality comparison from utils
        return !utils.jsonValuesEqual(a, b);
    }
};

/// Primary configuration loading function
pub fn loadConfig(
    allocator: std.mem.Allocator,
    options: types.LoadOptions,
) !types.ConfigResult {
    var loader = try ConfigLoader.init(allocator);
    return try loader.load(options);
}

/// Try loading config, return null on error
pub fn tryLoadConfig(
    allocator: std.mem.Allocator,
    options: types.LoadOptions,
) ?types.ConfigResult {
    return loadConfig(allocator, options) catch null;
}

test "loadConfig returns defaults when no file found" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    // Create defaults with proper ownership
    var defaults_obj = std.json.ObjectMap.init(allocator);
    defer defaults_obj.deinit();
    try defaults_obj.put("key", .{ .string = "value" });

    var result = try loadConfig(allocator, .{
        .name = "nonexistent",
        .cwd = cwd,
        .defaults = .{ .object = defaults_obj },
    });
    defer result.deinit();

    try std.testing.expectEqual(types.ConfigSource.defaults, result.source);
    try std.testing.expect(result.config.object.get("key") != null);
}

test "loadConfig loads from file" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("test.json", .{});
    defer file.close();
    try file.writeAll("{\"loaded\": true}");

    const cwd = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    var result = try loadConfig(allocator, .{
        .name = "test",
        .cwd = cwd,
    });
    defer result.deinit();

    try std.testing.expectEqual(types.ConfigSource.file_local, result.source);
    try std.testing.expect(result.config.object.get("loaded") != null);
}
