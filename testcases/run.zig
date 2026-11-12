// Runs the integration tests

const std = @import("std");

const MAX_OUTPUT_SIZE = 1024 * 1024; // 1MB

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        std.log.err("usage: {s} <path to ziglint executable>", .{args[0]});
        return;
    }

    const ziglint = try std.Io.Dir.cwd().realPathFileAlloc(io, args[1], allocator);
    defer allocator.free(ziglint);

    const stdout = std.Io.File.stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout_file_writer = stdout.writerStreaming(io, &stdout_buf);
    const stdout_writer = &stdout_file_writer.interface;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_file_writer = std.Io.File.stderr().writerStreaming(io, &stderr_buf);
    const stderr_writer = &stderr_file_writer.interface;

    const use_color = stdout.supportsAnsiEscapeCodes(io) catch false;

    const bold_green_text: []const u8 = if (use_color) "\x1b[1;32m" else "";
    const bold_red_text: []const u8 = if (use_color) "\x1b[1;31m" else "";
    const end_text_fmt: []const u8 = if (use_color) "\x1b[0m" else "";

    // iterate over all directories in . and run the integration tests
    var dir = try std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);

    var iterable = dir.iterate();
    var entry = try iterable.next(io);

    var failures = false;
    while (entry != null) : (entry = try iterable.next(io)) {
        if (entry.?.kind == .directory) {
            const name = entry.?.name;
            var test_directory = try std.Io.Dir.cwd().openDir(io, name, .{});
            defer test_directory.close(io);

            const expected_output = test_directory.readFileAlloc(
                io,
                "output.txt",
                allocator,
                .limited(MAX_OUTPUT_SIZE),
            ) catch |err| {
                switch (err) {
                    error.FileNotFound => {
                        std.log.err("test {s} has no output.txt file — skipping...", .{name});
                        continue;
                    },
                    else => {
                        std.log.err("unexpected error opening output.txt for test {s}: {t}", .{ name, err });
                        @panic("panicking...");
                    },
                }
            };
            defer allocator.free(expected_output);

            const expected_exit_code_text = test_directory.readFileAlloc(
                io,
                "exitcode.txt",
                allocator,
                .limited(5),
            ) catch null;
            defer {
                if (expected_exit_code_text) |text| allocator.free(text);
            }
            const expected_exit_code = if (expected_exit_code_text) |text|
                (try std.fmt.parseInt(u8, std.mem.trimEnd(u8, text, "\r\n"), 10))
            else
                null;

            // log to stdout
            try stdout_writer.print("Running integration test '{s}'...", .{name});
            try stdout_writer.flush();
            const is_gitignore = std.mem.eql(u8, name, "gitignore");
            if (is_gitignore) try test_directory.rename(".gitignore-test", test_directory, ".gitignore", io);

            const result = try std.process.run(allocator, io, .{
                .argv = &.{ziglint},
                .cwd = .{ .dir = test_directory },
            });
            defer {
                allocator.free(result.stderr);
                allocator.free(result.stdout);
            }

            if (is_gitignore) {
                test_directory.rename(".gitignore", test_directory, ".gitignore-test", io) catch {
                    std.log.err(
                        "******** FAILED TO RENAME testcases/gitignore/.gitignore-test TO .gitignore ********",
                        .{},
                    );
                };
            }

            // alphabetize expected and actual output
            const expected = try alphabetize(allocator, expected_output);
            defer allocator.free(expected);

            const actual = try alphabetize(allocator, result.stdout);
            defer allocator.free(actual);

            var i: usize = 0;
            while (i < expected.len and i < actual.len) : (i += 1) {
                std.testing.expectEqualStrings(expected[i], actual[i]) catch {
                    try stderr_writer.print(
                        "An integration test {s}FAILED{s}: '{s}'\n",
                        .{ bold_red_text, end_text_fmt, name },
                    );
                    try stderr_writer.flush();
                    failures = true;
                    continue;
                };
            }
            std.testing.expectEqual(expected.len, actual.len) catch {
                const expected_str = try std.mem.join(allocator, "\n", expected);
                defer allocator.free(expected_str);
                const actual_str = try std.mem.join(allocator, "\n", actual);
                defer allocator.free(actual_str);

                try stderr_writer.print("EXPECTED:\n{s}\nGOT:\n{s}\n", .{ expected_str, actual_str });
                try stderr_writer.print(
                    "An integration test {s}FAILED{s}: '{s}'\n",
                    .{ bold_red_text, end_text_fmt, name },
                );
                try stderr_writer.flush();
                failures = true;
                continue;
            };

            switch (result.term) {
                .exited => |exit_code| {
                    if (expected_exit_code) |code| {
                        std.testing.expectEqual(code, exit_code) catch {
                            try stderr_writer.print(
                                "An integration test {s}FAILED{s} by wrong exit code: '{s}'\n",
                                .{ bold_red_text, end_text_fmt, name },
                            );
                            try stderr_writer.flush();
                            failures = true;
                            continue;
                        };
                    }
                },
                else => {
                    try stderr_writer.print(
                        "An integration test {s}FAILED{s} by wrong termination: '{s}'\n",
                        .{ bold_red_text, end_text_fmt, name },
                    );
                    try stderr_writer.flush();
                    failures = true;
                    continue;
                },
            }

            try stdout_writer.print(" {s}ok{s}\n", .{ bold_green_text, end_text_fmt });
            try stdout_writer.flush();
        }
        if (failures) std.process.exit(1);
    }
}

// Splits by newline and alphabetizes test output
// Caller must deinit
fn alphabetize(allocator: std.mem.Allocator, input: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(allocator);

    var line_start: usize = 0;
    var idx: usize = 0;
    while (idx < input.len) : (idx += 1) {
        if (input[idx] == '\n') {
            const line = input[line_start..idx];
            try list.append(allocator, line);
            line_start = idx + 1;
        }
    }

    const result = try list.toOwnedSlice(allocator);

    // sort strings in result alphabetically
    std.sort.insertion([]const u8, result, .{}, less_than);
    return result;
}

fn less_than(_: @TypeOf(.{}), lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}
