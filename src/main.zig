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
                            var found = false;
                            // Read path environment variable
                            const path_env = std.os.environ;
                            outer_loop: for (path_env) |item| {
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
                                        defer allocator.free(dir_path);
                                        // check if file is executable if file is executable return
                                        if (std.posix.access(dir_path, std.posix.X_OK)) |_| {
                                            // 成功：找到了！
                                            try stdout.print("{s} is {s}\n", .{ command_name, dir_path });
                                            found = true;

                                            // 【关键修改】：这里只跳出循环，不要 exit！
                                            break :outer_loop;
                                        } else |_| {
                                            // 失败：当前目录下没有，或者不可执行。
                                            // 关键点：什么都不做，继续下一次循环！
                                            continue;
                                        }
                                    }
                                    // 既然已经找到了 PATH 环境变量并处理完了，就不需要再看其他环境变量了
                                    break;
                                }
                            }

                            // 【关键补充】：如果循环结束了还没找到，打印 not found
                            if (!found) {
                                try stdout.print("{s}: not found\n", .{command_name});
                            }
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
