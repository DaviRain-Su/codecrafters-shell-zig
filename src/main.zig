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
            // 注意：这里需要处理 args 为空的情况，否则 args.next().? 会 crash
            // 实际使用建议加个 if (args.peek() == null) check
            const cmd_str = args.next() orelse continue;
            const translated_command = std.meta.stringToEnum(Commands, cmd_str) orelse .notfound;
            switch (translated_command) {
                .type => {
                    const cmd = std.meta.stringToEnum(Commands, args.peek().?) orelse .notfound;
                    switch (cmd) {
                        .type, .echo, .exit => try stdout.print("{s} is a shell builtin\n", .{args.peek().?}),
                        .notfound => {
                            const command_name = command[args.index..];
                            var found = false;
                            // 1. 直接获取 PATH 环境变量 (如果不存在，默认为空字符串)
                            // std.posix.getenv 返回 ?[]const u8，如果为 null 则跳过
                            if (std.posix.getenv("PATH")) |path_env| {
                                var dirs = std.mem.splitScalar(u8, path_env, ':');
                                // 使用通用分配器，比在循环里反复创建 FixedBufferAllocator 更清晰
                                // 如果你非常在意性能，可以将 allocator 定义在 main 函数顶部传进来
                                const allocator = std.heap.page_allocator;
                                while (dirs.next()) |dir| {
                                    // 2. 拼接路径: dir + "/" + command_name
                                    const dir_path = try std.fs.path.join(allocator, &[_][]const u8{ dir, command_name });
                                    defer allocator.free(dir_path);
                                    // 3: check if file is executable if file is executable return
                                    if (std.posix.access(dir_path, std.posix.X_OK)) |_| {
                                        // 成功：找到了！
                                        try stdout.print("{s} is {s}\n", .{ command_name, dir_path });
                                        found = true;

                                        // 【关键修改】：这里只跳出循环，不要 exit！
                                        break;
                                    } else |_| {
                                        // 失败：当前目录下没有，或者不可执行。
                                        // 关键点：什么都不做，继续下一次循环！
                                        continue;
                                    }
                                }
                            }
                            // 4：如果循环结束了还没找到，打印 not found
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
