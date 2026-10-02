# zash architecture

zash is a bash implementation in Zig (Zig 0.16, std.Io). Goals in order: bash compatibility, then speed beyond bash on the commands coding agents run, then embeddability (library used by the di agent for in-process execution with a real-bash fallback).

## Layout

- `src/lexer.zig`, `src/ast.zig`, `src/parser.zig`: bash grammar to AST. Owned by the parser workstream.
- `src/interp/`: expansion, redirections, pipelines, jobs, builtins (`cd export read test [ [[ printf type command` ...). Owned by the interpreter workstream.
- `src/utils/*.zig`: in-process implementations of common utilities. Owned by the utilities workstream. Registered in `src/utils/registry.zig`.
- `src/main.zig`: CLI (`zash -c`, `zash script.sh`, interactive later).
- `src/root.zig`: library entry (`zash` module) for embedding.
- `tests/`: differential tests, real bash is the oracle.
- `bench/`: benchmark corpus and harness, zash vs bash.

## Utility contract (stable, shared by all workstreams)

Every in-process utility is a function with this exact signature in its own file:

```zig
pub fn run(ctx: *Ctx, argv: []const []const u8, io: Stdio) u8
```

`argv[0]` is the command name. Return value is the exit status.

```zig
pub const Stdio = struct {
    in: *std.Io.Reader,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
};

pub const Ctx = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    env: *const EnvView,
};
```

`Ctx` and `Stdio` live in `src/utils/common.zig`. A utility must: stream (never materialize all input unless the operation requires it, such as sort), stop early when the output side closes or `head` is satisfied (writers return `error.BrokenPipe` or a closed signal, propagate it as exit 141 semantics only where bash does), honor GNU option parsing for the supported subset, print GNU-style errors to `io.err`, and never read process-global state other than via `ctx`.

`src/utils/registry.zig` exposes `lookup(name: []const u8) ?UtilFn` and `supports(argv) bool`. `supports` returns false for any flag combination the in-process version does not implement exactly, so the caller falls back to the real executable. Exactness over coverage: a utility must never silently differ from GNU coreutils/grep/sed output for an argv it claims to support.

## Execution model

- Parse the whole script to AST first. Syntax errors match bash's exit status 2 and message shape.
- A pipeline of in-process utilities runs without fork or pipes: stages are connected by bounded in-memory buffers on one thread where possible, so `a | head -n 5` stops `a` early.
- Anything not in the registry (or `supports` false) is exec'd as a real process with the same stdio wiring.
- Errors: unsupported syntax is a hard parse error in zash (it targets full bash), but the di integration treats a failure to translate as a signal to use real bash.

## Conformance

`tests/differential/` holds cases as `name.sh` plus optional `name.stdin`. The runner executes each under `bash --norc --noprofile` and `zash`, compares stdout, stderr (normalized program name), and exit status. New features land with differential cases. Environment: tests run in a temp dir with a fixed fixture tree created by the runner.

## Benchmarks

`bench/corpus/*.sh` are sanitized synthetic commands that reflect what coding agents run (search pipelines, head/tail/cut/tr/sort/uniq/wc, sed, find, ls, git plumbing, loops, heredocs). The distribution of stages follows an analysis of about 135k real agent commands: head, rg, tail, sed, cut, cat, ls, grep, wc, tr, sort dominate; about 10 percent of commands contain a pipe. Do not commit real commands from private transcripts.
`bench/run.sh` times each corpus entry with hyperfine (zash vs bash), checks output equality against bash first, and writes a markdown table. A corpus entry whose outputs differ is reported as a failure, never a speedup.
