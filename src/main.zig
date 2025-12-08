const std = @import("std");

// define stdin
var stdin_buffer: [4096]u8 = undefined;
var stdin_readder = std.fs.File.stdin().readerStreaming(&stdin_buffer);
const stdin = &stdin_readder.interface;

// define stdout
var stdout_writer = std.fs.File.stdout().writerStreaming(&.{});
const stdout = &stdout_writer.interface;

pub fn main() !void {
    // TODO: Uncomment the code below to pass the first stage
    try stdout.print("$ ", .{});

    const command = try stdin.takeDelimiter('\n');
    try stdout.print("{s}: command not found\n", .{command.?});
}
