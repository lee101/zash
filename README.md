# zash

A bash implementation in Zig 0.16. Goals: bash compatibility, speed on the commands coding agents run, and embeddability as a library.

```
zig build -Dtarget=x86_64-linux-gnu
zig build test -Dtarget=x86_64-linux-gnu
./zig-out/bin/zash -c 'echo hello'
./zig-out/bin/zash --dump-ast -c 'a | b && c'
```

See docs/ARCHITECTURE.md for the layout. Licensed under Apache-2.0.
