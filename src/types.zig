const std = @import("std");

/// Configuration source type
pub const ConfigSource = enum {
    file_local,
    file_home,
    typescript,
    package_json,
    env_vars,
    defaults,
};

/// Array merge strategy for deep merge
pub const MergeStrategy = enum {
    replace, // Replace arrays entirely (default)
    concat, // Concatenate arrays with deduplication
    smart, // Merge object arrays by key (id, name, key, path, type)
};

/// Configuration loading options
pub const LoadOptions = struct {
    /// Configuration name (used for file discovery)
    name: []const u8,

    /// Default configuration values
    defaults: ?std.json.Value = null,

    /// Current working directory (defaults to process cwd)
    cwd: ?[]const u8 = null,

    /// Enable validation
    validate: bool = true,

    /// Enable caching
    cache: bool = true,

    /// Cache TTL in milliseconds (default 5 minutes)
    cache_ttl: u64 = 300_000,

    /// Environment variable prefix (defaults to uppercase name)
    env_prefix: ?[]const u8 = null,

    /// Array merge strategy
    merge_strategy: MergeStrategy = .smart,

    /// Nested key to extract from config (e.g., "den" to get {"den": {...}} -> {...})
    /// Supports dot notation for deep nesting: "tooling.shell" extracts {"tooling": {"shell": {...}}} -> {...}
    nested_key: ?[]const u8 = null,
};

/// Information about a configuration source
pub const SourceInfo = struct {
    source: ConfigSource,
    path: ?[]const u8,
    priority: u8,

    pub fn deinit(self: *SourceInfo, allocator: std.mem.Allocator) void {
        if (self.path) |p| {
            allocator.free(p);
        }
    }
};

/// Generic configuration loading result with type safety
pub fn ConfigResult(comptime T: type) type {
    return struct {
        /// The loaded and parsed configuration
        value: T,

        /// Primary source of the configuration
        source: ConfigSource,

        /// All sources that contributed to the configuration
        sources: []SourceInfo,

        /// Timestamp when configuration was loaded
        loaded_at: i64,

        /// Allocator used for this result
        allocator: std.mem.Allocator,

        // Store the parsed result for proper cleanup
        parsed_data: ?std.json.Parsed(T) = null,

        const Self = @This();

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            // Free the parsed config value through the Parsed wrapper if available
            if (self.parsed_data) |*parsed| {
                parsed.deinit();
            }
            _ = allocator; // parsed.deinit() handles the allocator internally

            // Free sources
            for (self.sources) |*source_item| {
                source_item.deinit(self.allocator);
            }
            self.allocator.free(self.sources);
        }
    };
}

/// Legacy untyped configuration result (for internal use)
pub const UntypedConfigResult = struct {
    /// The loaded configuration
    config: std.json.Value,

    /// Primary source of the configuration
    source: ConfigSource,

    /// All sources that contributed to the configuration
    sources: []SourceInfo,

    /// Timestamp when configuration was loaded
    loaded_at: i64,

    /// Allocator used for this result
    allocator: std.mem.Allocator,

    /// Parsed JSON data (if loaded from JSON file)
    parsed_json: ?std.json.Parsed(std.json.Value) = null,

    /// Whether config was modified after parsing (e.g., by env vars)
    config_was_modified: bool = false,

    pub fn deinit(self: *UntypedConfigResult) void {
        const utils = @import("utils.zig");

        // The config field always comes from applyEnvVars which creates new allocations
        // So we always need to free it
        utils.freeJsonValue(self.allocator, self.config);

        // If we have parsed JSON data, also free the arena
        if (self.parsed_json) |*parsed| {
            parsed.deinit();
        }

        // Free sources
        for (self.sources) |*source| {
            source.deinit(self.allocator);
        }
        self.allocator.free(self.sources);
    }

    /// Convert to typed result
    pub fn toTyped(self: *UntypedConfigResult, comptime T: type) !ConfigResult(T) {
        // Parse JSON value into struct
        const parsed = try std.json.parseFromValue(T, self.allocator, self.config, .{
            .allocate = .alloc_always,
        });

        return ConfigResult(T){
            .value = parsed.value,
            .source = self.source,
            .sources = self.sources,
            .loaded_at = self.loaded_at,
            .allocator = self.allocator,
            .parsed_data = parsed,
        };
    }
};

/// Merge options for deep merge
pub const MergeOptions = struct {
    strategy: MergeStrategy = .smart,
    allow_undefined: bool = false,
};

test "ConfigSource enum values" {
    try std.testing.expect(@intFromEnum(ConfigSource.file_local) == 0);
    try std.testing.expect(@intFromEnum(ConfigSource.defaults) == 5);
}

test "MergeStrategy enum values" {
    try std.testing.expect(@intFromEnum(MergeStrategy.replace) == 0);
    try std.testing.expect(@intFromEnum(MergeStrategy.smart) == 2);
}

test "LoadOptions default values" {
    const options = LoadOptions{
        .name = "test",
    };

    try std.testing.expectEqual(true, options.validate);
    try std.testing.expectEqual(true, options.cache);
    try std.testing.expectEqual(@as(u64, 300_000), options.cache_ttl);
    try std.testing.expectEqual(MergeStrategy.smart, options.merge_strategy);
}

test "SourceInfo deinit frees path" {
    const allocator = std.testing.allocator;

    var source = SourceInfo{
        .source = .file_local,
        .path = try allocator.dupe(u8, "/path/to/config.json"),
        .priority = 1,
    };
    defer source.deinit(allocator);

    try std.testing.expect(source.path != null);
}
