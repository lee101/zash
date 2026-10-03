pub const sys = @import("sys.zig");
pub const shell = @import("shell.zig");
pub const exec = @import("exec.zig");
pub const builtins = @import("builtins.zig");
pub const Shell = shell.Shell;
pub const setup = @import("interp.zig").setup;
pub const run_script = @import("interp.zig").run_script;
pub const finish = @import("interp.zig").finish;

test {
    _ = @import("bump.zig");
    _ = @import("vars.zig");
    _ = @import("pattern.zig");
    _ = @import("builtins.zig");
    _ = @import("tests.zig");
}
