//! Handles upgrading the ziglint binary.

const std = @import("std");
const builtin = @import("builtin");
const semver = @import("./semver.zig");
const stderr_print = @import("./main.zig").stderr_print;

const RELEASE_API_URI =
    std.Uri.parse("https://api.github.com/repos/scheibo/ziglint/releases/latest") catch unreachable;
const FALLBACK_API_URI =
    std.Uri.parse("https://api.github.com/repos/scheibo/ziglint/releases/tags/latest") catch unreachable;

const GithubReleaseAsset = struct {
    url: []const u8,
    browser_download_url: ?[]const u8 = null,
    name: []const u8,
    content_type: []const u8,
    size: u32,

    pub fn format(value: GithubReleaseAsset, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print(
            "GithubReleaseAsset{{ .name = \"{s}\", .url = \"{s}\", .size = {d}, .content_type = \"{s}\" }}",
            .{ value.name, value.url, value.size, value.content_type },
        );
    }
};

// The GitHub API response for a release.
// See the schema here: https://docs.github.com/en/rest/releases/releases?apiVersion=2022-11-28#get-the-latest-release
// We ignore fields that aren't necessary for `ziglint upgrade`.
const GithubRelease = struct {
    name: []const u8,
    assets: []GithubReleaseAsset,

    pub fn format(value: GithubRelease, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("GithubRelease{{\n", .{});
        const info = @typeInfo(GithubRelease).@"struct";
        inline for (info.field_names, info.field_types) |field_name, FieldType| {
            try writer.print("    .{s} = ", .{field_name});
            switch (FieldType) {
                []const u8 => try writer.print("\"{s}\",\n", .{@field(value, field_name)}),
                []GithubReleaseAsset => {
                    try writer.print("[\n", .{});
                    for (@field(value, field_name)) |asset| {
                        try writer.print("        {f},\n", .{asset});
                    }
                    try writer.print("    ],\n", .{});
                },
                else => try writer.print("{any},\n", .{@field(value, field_name)}),
            }
        }
        try writer.print("}}", .{});
    }
};

pub fn upgrade(
    io: std.Io,
    alloc: std.mem.Allocator,
    current_version: semver.Version,
    override_url: ?[]const u8,
) !void {
    const api_url = if (override_url == null) RELEASE_API_URI else std.Uri.parse(override_url.?) catch |err| errblk: {
        try stderr_print(
            io,
            "couldn't parse specified API URL '{s}' ({t}); using the default GitHub endpoint instead",
            .{ override_url.?, err },
        );
        break :errblk RELEASE_API_URI;
    };

    const latest_release = access_api(io, alloc, api_url) catch |err| blk: {
        switch (err) {
            error.MissingField => {
                try stderr_print(
                    io,
                    "error: couldn't parse latest release JSON: missing important field\n" ++
                        "maybe the API URL is broken, GitHub has changed their API, or there's no latest release?\n",
                    .{},
                );
            },
            // pass it up
            else => {},
        }

        if (override_url == null) {
            try stderr_print(
                io,
                "error: couldn't access GitHub API endpoint due to {t}; trying fallback endpoint",
                .{err},
            );
            break :blk try access_api(io, alloc, FALLBACK_API_URI);
        } else {
            try stderr_print(io, "error: couldn't access GitHub API endpoint due to {t}", .{err});
            std.process.exit(1);
        }
    };
    defer latest_release.deinit();

    var release_name = latest_release.value.name;
    const latest_version = semver.Version.parse(release_name) catch errblk: {
        // try cutting off the leading "v" if it exists
        if (release_name.len > 0 and release_name[0] == 'v') {
            release_name = release_name[1..];
            break :errblk semver.Version.parse(release_name) catch {
                log_failure_to_parse_version_and_exit(io, release_name);
            };
        }
        // cut off stuff before a space
        const space = std.mem.indexOf(u8, release_name, " ");
        if (space) |space_idx| {
            release_name = release_name[space_idx + 1 ..];
            break :errblk semver.Version.parse(release_name) catch
                log_failure_to_parse_version_and_exit(io, release_name);
        }
        try stderr_print(
            io,
            "error: couldn't parse latest release name '{s}' (nor '{s}') as a version",
            .{ latest_release.value.name, release_name },
        );
        std.process.exit(1);
    };

    if (!latest_version.has_precendence_over(current_version)) {
        try stderr_print(io, "the current version ({f}) is up to date", .{current_version});
        return;
    }

    const extension = comptime builtin.target.exeFileExt();
    const target = @tagName(builtin.target.os.tag) ++ "-" ++ @tagName(builtin.target.cpu.arch);
    const executable_name = "ziglint-" ++ target ++ extension;

    // find the asset with the name "ziglint-<platform>-<arch>"
    for (latest_release.value.assets) |asset| {
        if (std.mem.eql(u8, asset.name, executable_name)) {
            try stderr_print(io, "downloading {s} version {f}...", .{ asset.name, latest_version });

            const download_url = asset.browser_download_url orelse asset.url;
            const uri = try std.Uri.parse(download_url);
            var client: std.http.Client = .{ .allocator = alloc, .io = io };
            defer client.deinit();

            var download: std.Io.Writer.Allocating = .init(alloc);
            defer download.deinit();

            const extra_headers: []const std.http.Header = if (asset.browser_download_url == null)
                &.{.{ .name = "Accept", .value = "application/octet-stream" }}
            else
                &.{};

            const response = try client.fetch(.{
                .location = .{ .uri = uri },
                .extra_headers = extra_headers,
                .response_writer = &download.writer,
            });

            if (response.status != .ok) {
                try stderr_print(
                    io,
                    "error: couldn't download {s} version {f}: HTTP status {t}",
                    .{ asset.name, latest_version, response.status },
                );
                std.process.exit(1);
            }

            const binary_bytes = download.writer.buffered();

            // replace ourselves with a new ziglint
            const our_path = try std.process.executablePathAlloc(io, alloc);
            defer alloc.free(our_path);
            if (builtin.target.os.tag == .linux and std.mem.endsWith(u8, our_path, " (deleted)")) {
                try stderr_print(io, "it looks like your ziglint binary ('{s}') was deleted while it was running;" ++
                    "it will be reinstalled, but if you really are trying to name your ziglint '(deleted)', " ++
                    "you should rename it afterwards!", .{our_path});
            }

            install_executable(io, .cwd(), our_path, binary_bytes) catch |err| {
                // if we can move the new ziglint to /usr/local/bin (on Mac/Linux) or C:\Program Files (on Windows),
                // we do so
                const local_bin = if (builtin.target.os.tag == .windows) "C:\\Program Files" else "/usr/local/bin";
                const local_name = "ziglint" ++ extension;
                var dest_dir = try std.Io.Dir.openDirAbsolute(io, local_bin, .{});
                defer dest_dir.close(io);

                install_executable(io, dest_dir, local_name, binary_bytes) catch |err2| {
                    if (std.Io.Dir.cwd().statFile(io, local_name, .{}) == error.FileNotFound) {
                        install_executable(io, .cwd(), local_name, binary_bytes) catch |err3| {
                            try stderr_print(
                                io,
                                "error: couldn't replace myself, copy the new ziglint to {s}," ++
                                    "or copy it to the current directory\n" ++
                                    "errors: {t}, {t}, {t}",
                                .{ local_bin, err, err2, err3 },
                            );
                            std.process.exit(1);
                        };
                        try stderr_print(io, "couldn't replace the ziglint you're running with the new version;" ++
                            "installed ziglint to the current directory instead", .{});
                    } else {
                        try stderr_print(io, "couldn't replace the ziglint you're running with the new version " ++
                            "or install ziglint in an alternate location." ++
                            "try deleting the ziglint file from your current directory " ++
                            "or giving this program permissions to modify {s}.", .{local_bin});
                    }
                    return;
                };
                try stderr_print(io, "couldn't replace the ziglint you're running with the new version; " ++
                    "installed ziglint to {s} instead", .{local_bin});
                return;
            };
            try stderr_print(io, "successfully upgraded ziglint to version {f}!", .{latest_version});

            return;
        }
    }
    try stderr_print(
        io,
        "version {f} of ziglint has been released (you're running version {f}), " ++
            "but it's not currently available for your processor and operating system ({s}).",
        .{ latest_version, current_version, target },
    );
}

fn install_executable(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, bytes: []const u8) !void {
    var atomic_file = try dir.createFileAtomic(io, sub_path, .{
        .permissions = .executable_file,
        .replace = true,
    });
    defer atomic_file.deinit(io);
    try atomic_file.file.writeStreamingAll(io, bytes);
    try atomic_file.replace(io);
}

// caller must free with Parsed.deinit()
fn access_api(io: std.Io, alloc: std.mem.Allocator, api_url: std.Uri) !std.json.Parsed(GithubRelease) {
    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();

    const response = try client.fetch(.{
        .location = .{ .uri = api_url },
        .response_writer = &aw.writer,
    });
    if (response.status != .ok) return error.HttpStatusNotOk;

    return std.json.parseFromSlice(GithubRelease, alloc, aw.writer.buffered(), .{ .ignore_unknown_fields = true });
}

fn log_failure_to_parse_version_and_exit(io: std.Io, release_name: []const u8) noreturn {
    stderr_print(io, "error: couldn't parse latest release name '{s}' as a version", .{release_name}) catch unreachable;
    std.process.exit(1);
}
