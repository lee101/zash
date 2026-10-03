# zash

A bash implementation in Zig 0.16. Goals: bash compatibility, speed on the commands coding agents run, and embeddability as a library.

```
zig build -Dtarget=x86_64-linux-gnu
zig build test -Dtarget=x86_64-linux-gnu
./zig-out/bin/zash -c 'echo hello'
./zig-out/bin/zash --dump-ast -c 'a | b && c'
```

On linux x86_64 the executable is built as a static musl binary regardless of the requested libc (about 0.3ms startup, versus 0.55ms dynamically linked); pass `-Dstatic=false` to link the requested target's libc dynamically. The `zash` library module always uses the requested target. `[[ x =~ re ]]` uses the linked libc's regcomp, so the static build follows musl regex semantics (no ERE back-references, `\d` accepted).

Benchmarks: `bench/run.sh` (agent corpus, zash vs bash), `bench/stress.sh` (large inputs), `bench/gate.sh` (regression gate). Current numbers are in bench/results.md.

Parser checks: `zig build parse-bench` times the parser, and `tests/syntax/crosscheck.sh` compares accept and reject decisions and error messages against real `bash -n` for the cases in `tests/syntax/corpus.txt`.

See docs/ARCHITECTURE.md for the layout. Licensed under Apache-2.0.
