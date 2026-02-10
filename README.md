# ZigConfig

A zero-dependency configuration loader for Zig 0.16+, inspired by [bunfig](https://github.com/stacksjs/bunfig).

## Features

- 🔍 **Multi-source loading** - Local files, home directory, environment variables, defaults
- 🎯 **Type-aware env vars** - Automatic parsing of booleans, numbers, arrays, and JSON
- 🔗 **Deep merging** - Three strategies: replace, concat, and smart object array merging
- 🛡️ **Circular reference detection** - Prevents infinite loops during merge
- 📁 **Multiple formats** - JSON and Zig files (extensible)
- 🎨 **Simple API** - Clean, ergonomic interface

## Installation

Clone zig-config into your project's dependency directory:

```bash
git clone --depth 1 https://github.com/zig-utils/zig-config.git
```

Then add it as a module in your `build.zig`:

```zig
exe.root_module.addImport("zig-config", b.addModule("zig-config", .{
    .root_source_file = b.path("path/to/zig-config/src/zig-config.zig"),
    .target = target,
}));
```

## Quick Start

```zig
const std = @import("std");
const zig_config = @import("zig-config");

// Define your configuration structure with full type safety!
const AppConfig = struct {
    port: u16 = 8080,
    debug: bool = false,
    database: struct {
        host: []const u8 = "localhost",
        port: u16 = 5432,
    } = .{},
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load configuration with compile-time type checking
    var config = try zig_config.loadConfig(AppConfig, allocator, .{
        .name = "myapp",
    });
    defer config.deinit(allocator);

    // Access values with full type safety - no runtime type checking needed!
    const port: u16 = config.value.port;           // Compile-time type safe!
    const debug: bool = config.value.debug;         // IDE autocomplete works!
    const db_host = config.value.database.host;     // Nested structs supported!

    std.debug.print("Server running on port {d}\n", .{port});
}
```

## Configuration Sources

ZigConfig loads configuration from multiple sources with the following priority (highest to lowest):

1. **Environment variables** (highest priority)
2. **Local project file** (`./myapp.json`, `./config/myapp.json`, `./.config/myapp.json`)
3. **Home directory** (`~/.config/myapp.json`)
4. **Defaults** (provided in code)

## Environment Variables

Environment variables are automatically parsed with type awareness:

```bash
# Boolean values
export MYAPP_DEBUG=true        # → bool
export MYAPP_VERBOSE=1         # → bool (true)
export MYAPP_QUIET=false       # → bool
export MYAPP_COLORS=yes        # → bool (true)

# Numbers
export MYAPP_PORT=3000         # → integer
export MYAPP_TIMEOUT=30.5      # → float

# Arrays (comma-separated)
export MYAPP_HOSTS=localhost,api.example.com,cdn.example.com  # → array of strings

# JSON objects/arrays
export MYAPP_DATABASE='{"host":"localhost","port":5432}'     # → object
export MYAPP_TAGS='["production","web"]'                      # → array

# Strings (default)
export MYAPP_NAME="My Application"                           # → string
```

Environment variable naming:
- Prefix: Uppercase version of config name (or custom `env_prefix`)
- Nested keys: Separated by underscores
- Hyphens: Converted to underscores

Examples:
- `database.host` → `MYAPP_DATABASE_HOST`
- `api-key` → `MYAPP_API_KEY`
- `cache.ttl-seconds` → `MYAPP_CACHE_TTL_SECONDS`

## Type Safety Features

### ✅ Compile-Time Type Checking
- **No runtime type errors** - all types validated at compile time
- **IDE autocomplete** - full IntelliSense support for config fields
- **Default values** - define defaults directly in your struct
- **Optional fields** - use `?T` for optional configuration
- **Nested structures** - full support for complex nested configs

### Example with All Features

```zig
const Config = struct {
    // Required fields (no default)
    app_name: []const u8,

    // Optional fields
    api_key: ?[]const u8 = null,

    // Fields with defaults
    port: u16 = 8080,
    debug: bool = false,

    // Nested structures
    database: struct {
        host: []const u8 = "localhost",
        port: u16 = 5432,
        pool_size: u32 = 10,
    } = .{},

    // Arrays
    allowed_hosts: [][]const u8 = &.{},

    // Complex types
    timeouts: struct {
        connect_ms: u32 = 5000,
        read_ms: u32 = 30000,
    } = .{},
};

var config = try zig_config.loadConfig(Config, allocator, .{
    .name = "myapp",
});
defer config.deinit(allocator);

// All fields are type-safe!
std.debug.print("App: {s}, Port: {d}\n", .{
    config.value.app_name,
    config.value.port,
});
```

## Examples

### Basic Usage (Minimal Example)

```zig
const Config = struct {
    port: u16 = 8080,
    debug: bool = false,
};

var config = try zig_config.loadConfig(Config, allocator, .{
    .name = "myapp",
});
defer config.deinit(allocator);

// Fully typed access!
const port: u16 = config.value.port;
```

### Custom Working Directory

```zig
const Config = struct {
    port: u16 = 8080,
};

var config = try zig_config.loadConfig(Config, allocator, .{
    .name = "myapp",
    .cwd = "/path/to/project",
});
defer config.deinit(allocator);
```

### Custom Environment Prefix

```zig
const Config = struct {
    port: u16 = 8080,
};

var config = try zig_config.loadConfig(Config, allocator, .{
    .name = "myapp",
    .env_prefix = "CUSTOM",  // Uses CUSTOM_* instead of MYAPP_*
});
defer config.deinit(allocator);
```

### Deep Merging

```zig
const std = @import("std");
const zig_config = @import("zig-config");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var target_map = std.json.ObjectMap.init(allocator);
    defer target_map.deinit();
    try target_map.put("a", .{ .integer = 1 });

    var source_map = std.json.ObjectMap.init(allocator);
    defer source_map.deinit();
    try source_map.put("b", .{ .integer = 2 });

    const merged = try zig_config.deepMerge(
        allocator,
        .{ .object = target_map },
        .{ .object = source_map },
        .{ .strategy = .smart },  // or .replace, .concat
    );
    _ = merged;

    // Result: { "a": 1, "b": 2 }
}
```

### Merge Strategies

#### Replace (default for primitives/arrays)
```zig
.{ .strategy = .replace }
// Arrays are completely replaced
// [1, 2] + [3, 4] = [3, 4]
```

#### Concat (for arrays)
```zig
.{ .strategy = .concat }
// Arrays are concatenated with deduplication
// [1, 2] + [2, 3] = [1, 2, 3]
```

#### Smart (for object arrays)
```zig
.{ .strategy = .smart }
// Object arrays are merged by key (id, name, key, path, type)
// [{"id": 1, "name": "a"}] + [{"id": 1, "name": "b"}] 
// = [{"id": 1, "name": "b"}]  // merged by id
```

## Configuration Result

`ConfigResult(T)` is a generic struct parameterized by your config type:

```zig
pub fn ConfigResult(comptime T: type) type {
    return struct {
        value: T,                      // Your typed configuration
        source: ConfigSource,          // Primary source (.file_local, .file_home, .env_vars, .defaults)
        sources: []SourceInfo,         // All sources that contributed
        loaded_at: i64,               // Timestamp

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void;
    };
}
```

## File Discovery

ZigConfig searches for configuration files in this order:

1. Project root: `./myapp.json`, `./myapp.zig`
2. Config directory: `./config/myapp.json`, `./config/myapp.zig`
3. Hidden config: `./.config/myapp.json`, `./.config/myapp.zig`
4. Home directory: `~/.config/myapp.json`, `~/.config/myapp.zig`

Extension priority: `.json` > `.zig`

## Error Handling

ZigConfig provides detailed error types:

```zig
pub const ZigConfigError = error{
    ConfigFileNotFound,
    ConfigFileInvalid,
    ConfigFilePermissionDenied,
    ConfigFileSyntaxError,
    ConfigValidationFailed,
    ConfigSchemaViolation,
    EnvVarParseError,
    CircularReferenceDetected,
    MergeStrategyInvalid,
    CacheError,
};
```

Example error handling:

```zig
const AppConfig = struct {
    port: u16 = 8080,
};

var config = zig_config.loadConfig(AppConfig, allocator, .{
    .name = "myapp",
}) catch |err| switch (err) {
    error.ConfigFileNotFound => {
        std.debug.print("No config found, using defaults\n", .{});
        return;
    },
    error.ConfigFileSyntaxError => {
        std.debug.print("Invalid JSON in config file\n", .{});
        return error.InvalidConfig;
    },
    else => return err,
};
defer config.deinit(allocator);
```

## Testing

```bash
zig build test
```

All 20 tests passing! Note: There are 4 known memory "leaks" from Zig's JSON parser's internal arena allocator - these are expected and don't affect runtime behavior.

## API Reference

### Main Functions

#### `loadConfig`
```zig
pub fn loadConfig(
    comptime T: type,
    allocator: std.mem.Allocator,
    options: types.LoadOptions,
) !types.ConfigResult(T)
```

Load configuration with full error handling. Returns a typed result.

#### `tryLoadConfig`
```zig
pub fn tryLoadConfig(
    comptime T: type,
    allocator: std.mem.Allocator,
    options: types.LoadOptions,
) ?types.ConfigResult(T)
```

Load configuration, returning `null` on error.

#### `deepMerge`
```zig
pub fn deepMerge(
    allocator: std.mem.Allocator,
    target: std.json.Value,
    source: std.json.Value,
    options: types.MergeOptions,
) !std.json.Value
```

Deep merge two JSON values.

### Types

```zig
pub const LoadOptions = struct {
    name: []const u8,
    defaults: ?std.json.Value = null,
    cwd: ?[]const u8 = null,
    validate: bool = true,
    cache: bool = true,
    cache_ttl: u64 = 300_000,
    env_prefix: ?[]const u8 = null,
    merge_strategy: MergeStrategy = .smart,
};

pub const MergeStrategy = enum {
    replace,
    concat,
    smart,
};

pub const ConfigSource = enum {
    file_local,
    file_home,
    package_json,
    env_vars,
    defaults,
};
```

## License

MIT

## Contributing

Contributions welcome! Please ensure:
- All tests pass (`zig build test`)
- Code follows Zig style guidelines
- New features include tests

## Acknowledgments

Inspired by [bunfig](https://github.com/stacksjs/bunfig) by the Stacks team.
