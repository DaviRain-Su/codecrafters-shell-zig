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
                        .type => try stdout.print("{s} is a shell builtin\n", .{args.peek().?}),
                        .echo => try stdout.print("{s} is a shell builtin\n", .{args.peek().?}),
                        .exit => try stdout.print("{s} is a shell builtin\n", .{args.peek().?}),
                        .notfound => try stdout.print("{s}: command not found\n", .{ .command = command }),
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
