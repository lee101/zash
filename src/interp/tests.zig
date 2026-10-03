const std = @import("std");
const sys = @import("sys.zig");
const shell = @import("shell.zig");
const interp = @import("interp.zig");

fn run(src: []const u8) ![]u8 {
    const a = std.testing.allocator;
    const fd = sys.memfd_create("zash-test", 0);
    try std.testing.expect(fd >= 0);
    defer _ = sys.close(fd);
    const pid = sys.fork();
    try std.testing.expect(pid >= 0);
    if (pid == 0) {
        _ = sys.dup2(fd, 1);
        _ = sys.dup2(fd, 2);
        const gpa = std.heap.c_allocator;
        const io = std.Io.Threaded.global_single_threaded.io();
        const sh = shell.Shell.init(gpa, io) catch sys._exit(99);
        const env = [_]?[*:0]const u8{ "PATH=/usr/bin:/bin", "HOME=/tmp", null };
        interp.setup(sh, &env, "test.sh") catch sys._exit(98);
        const st = interp.run_script(sh, src, "test.sh");
        sys._exit(st);
    }
    var wst: c_int = 0;
    _ = sys.waitpid(pid, &wst, 0);
    const size: usize = @intCast(sys.lseek(fd, 0, 2));
    _ = sys.lseek(fd, 0, 0);
    const out = try a.alloc(u8, size);
    var got: usize = 0;
    while (got < size) {
        const n = sys.read_some(fd, out[got..]);
        if (n <= 0) break;
        got += @intCast(n);
    }
    return out[0..got];
}

fn expect_out(src: []const u8, want: []const u8) !void {
    const out = try run(src);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(want, out);
}

test "echo and variables" {
    try expect_out("x=hello; echo $x ${x^^} ${#x} ${x:1:3}", "hello HELLO 5 ell\n");
}

test "arithmetic" {
    try expect_out("echo $((2**10)) $((7/2)) $((-7%3)) $((1<<4)) $((3>2?5:6))", "1024 3 -1 16 5\n");
}

test "arrays and assoc order" {
    try expect_out("a=(x y z); echo ${#a[@]} ${a[1]} ${a[@]:1}; declare -A m=([a]=1 [b]=2); echo ${!m[@]}", "3 y y z\nb a\n");
}

test "functions locals and return" {
    try expect_out("f() { local x=$1; echo in:$x; return 3; }; x=g; f a; echo $? $x", "in:a\n3 g\n");
}

test "control flow" {
    try expect_out("for i in 1 2 3; do [ $i = 2 ] && continue; echo $i; done; case ab in a*) echo m;; esac; while false; do :; done", "1\n3\nm\n");
}

test "quoting and splitting" {
    try expect_out("v='a  b'; set -- $v; echo $#; set -- \"$v\"; echo $#; IFS=,; x=a,b; set -- $x; echo $#", "2\n1\n2\n");
}

test "command substitution and subshell" {
    try expect_out("x=$(echo a; echo b); echo \"[$x]\"; (y=1; echo $y); echo ${y-unset}", "[a\nb]\n1\nunset\n");
}

test "heredoc and here-string" {
    try expect_out("cat <<EOF\nx=$((1+1))\nEOF\ncat <<< hi", "x=2\nhi\n");
}

test "pipelines and PIPESTATUS" {
    try expect_out("printf 'b\\na\\n' | cat | head -1; echo ${PIPESTATUS[@]}; false | true; echo ${PIPESTATUS[@]}", "b\n0 0 0\n1 0\n");
}

test "traps and errexit" {
    try expect_out("trap 'echo bye' EXIT; set -e; echo a; false; echo not", "a\nbye\n");
}

test "printf and read" {
    try expect_out("printf '%05d|%-3s|%x\\n' 42 ab 255; read a b <<< '1 2 3'; echo $a-$b", "00042|ab |ff\n1-2 3\n");
}

test "brace and param expansion" {
    try expect_out("echo {a,b}{1,2} {1..3}; f=/a/b.txt; echo ${f##*/} ${f%.*} ${f/b/X}", "a1 a2 b1 b2 1 2 3\nb.txt /a/b /a/X.txt\n");
}

test "conditionals" {
    try expect_out("[[ abc == a* ]] && echo y; [[ abc =~ ^a(b)c$ ]] && echo ${BASH_REMATCH[1]}; [ 3 -gt 2 ] && echo gt", "y\nb\ngt\n");
}

test "getopts" {
    try expect_out("set -- -a -b val rest; while getopts ab: o; do echo $o:$OPTARG; done; echo $OPTIND", "a:\nb:val\n4\n");
}

test "alias expansion on later lines" {
    try expect_out("shopt -s expand_aliases\nalias e='echo pre'\ne a b", "pre a b\n");
}
