const std = @import("std");

// define stdin
var stdin_buffer: [4096]u8 = undefined;
var stdin_readder = std.fs.File.stdin().readerStreaming(&stdin_buffer);
const stdin = &stdin_readder.interface;

// define stdout
var stdout_writer = std.fs.File.stdout().writerStreaming(&.{});
const stdout = &stdout_writer.interface;

const Commands = enum {
    type,
    echo,
    exit,
    notfound,
};

pub fn main() !void {
    while (true) {
        const command = try prompt("$ ");
        if (command.len == 0) {
            continue;
        } else {
            var args = std.mem.tokenizeScalar(u8, command, ' ');
            const translated_command = std.meta.stringToEnum(Commands, args.next().?) orelse .notfound;
            switch (translated_command) {
                .type => {
                    const cmd = std.meta.stringToEnum(Commands, args.peek().?) orelse .notfound;
                    switch (cmd) {
                        .type, .echo, .exit => try stdout.print("{s} is a shell builtin\n", .{args.peek().?}),
                        .notfound => {
                            const command_name = command[args.index..];
                            // Read path environment variable
                            const path_env = std.os.environ;
                            for (path_env) |item| {
                                //convert to string
                                const item_str = std.mem.span(item);
                                if (std.mem.startsWith(u8, item_str, "PATH=")) {
                                    const path = item["PATH=".len..];
                                    // ls directory
                                    const path_str = std.mem.span(path);
                                    var dirs = std.mem.splitAny(u8, path_str, ":");
                                    while (dirs.next()) |dir| {
                                        // allocate memory for dir_path
                                        var buffer = [_]u8{0} ** 1024;
                                        var fixed_buffer_allocator = std.heap.FixedBufferAllocator.init(&buffer);
                                        const allocator = fixed_buffer_allocator.allocator();
                                        // seem don't to free
                                        //errdefer fixed_buffer_allocator.free();
                                        const dir_path = try std.fs.path.join(allocator, &[_][]const u8{ dir, command_name });
                                        const file = std.fs.openFileAbsolute(dir_path, .{}) catch {
                                            try stdout.print("{s}: not found\n", .{command_name});
                                            return std.process.exit(1);
                                        };
                                        defer file.close();
                                        const status = try file.stat();
                                        switch (status.kind) {
                                            std.fs.File.Kind.directory => {
                                                try stdout.print("{s} is a directory\n", .{dir_path});
                                                return;
                                            },
                                            std.fs.File.Kind.file => {
                                                // check if is executable permission
                                                if (status.mode & 0o111 != 0) {
                                                    try stdout.print("{s} is {s}\n", .{ command_name, dir_path });
                                                } else {
                                                    try stdout.print("{s} is a file\n", .{dir_path});
                                                }
                                                return;
                                            },
                                            else => {
                                                try stdout.print("{s} is not a file or directory\n", .{dir_path});
                                                return;
                                            },
                                        }
                                    }
                                }
                            }

                            try stdout.print("{s}: not found\n", .{command_name});
                        },
                    }
                },
                .echo => try stdout.print("{s}\n", .{command[args.index + 1 ..]}),
                .exit => return std.process.exit(0),
                .notfound => try stdout.print("{s}: command not found\n", .{ .command = command }),
            }
        }
    }
}

fn prompt(comptime question: []const u8) ![]u8 {
    try stdout.print(question, .{});
    return try stdin.takeDelimiter('\n') orelse "";
}
