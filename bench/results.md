# zash vs bash results

Harness: `bench/run.sh` (agent corpus, 630 entries, hyperfine `-N`, 20 runs, 3 warmup, median), `bench/stress.sh` (200MB log). Every entry is output-checked against bash before it is timed; speedup is bash median over zash median. Build: `zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseFast` (static musl executable). Machine: 32-core Linux VM under load, so single entries under about 2ms are noisy by 10 to 20 percent; category geomeans are stable to about 2 percent.

## Agent corpus, before and after

| category | entries | before geomean | after geomean | after median | zash median ms (before / after) |
|---|---|---|---|---|---|
| search | 110 | 1.12x | 1.45x | 1.21x | 4.80 / 4.10 |
| text-pipeline | 116 | 1.33x | 2.33x | 2.45x | 1.41 / 0.75 |
| fs-listing | 110 | 1.12x | 1.88x | 1.65x | 1.58 / 1.09 |
| control-flow | 190 | 1.42x | 2.51x | 2.51x | 1.39 / 0.73 |
| git | 70 | 1.05x | 1.27x | 1.27x | 2.70 / 2.13 |
| startup | 34 | 1.21x | 2.79x | 2.76x | 0.81 / 0.34 |
| all | 630 | 1.24x | 1.99x | | |

The 14 corpus entries that need `logs/huge.log` (`--big 50m,500m`) go from 0.85x to 2.50x geomean; the old figure includes `grep -c` entries where GNU grep stops at the first match because stdout is /dev/null.

Startup (`zash -c true` with a small environment): 0.77ms to 0.30ms, bash 0.86ms.

## Stress (200MB log, `bench/stress/corpus`)

Geomean 3.41x; all 14 entries output-equal and faster.

| entry | bash ms | zash ms | speedup |
|---|---|---|---|
| `cat logs/big.log \| grep -m 2 ERROR` | 73.29 | 0.83 | 87.9x |
| `cat logs/big.log \| head -n 3` | 4.90 | 0.51 | 9.5x |
| `cut -d' ' -f2 logs/big.log \| head -n 3` | 2.32 | 0.73 | 3.2x |
| `head -n 5 logs/big.log \| wc -l` | 1.74 | 0.57 | 3.1x |
| `tail -n 2 logs/big.log` | 1.34 | 0.46 | 2.9x |
| `tr a-z A-Z < logs/big.log \| head -n 2` | 2.06 | 0.73 | 2.8x |
| `grep -c ERROR logs/big.log > /dev/null` | 1.92 | 0.72 | 2.7x |
| `grep -m 1 ERROR logs/big.log \| cut -c1-20` | 1.94 | 0.80 | 2.4x |
| `grep -m 3 ERROR logs/big.log` | 1.58 | 0.69 | 2.3x |
| `grep ERROR logs/big.log \| head -n 5` | 1.98 | 0.87 | 2.3x |
| `cat logs/big.log \| tr -s ' ' \| cut -d' ' -f1,2 \| head -n 4` | 2.22 | 1.04 | 2.1x |
| `yes \| head -n 1000000 \| wc -l` | 3.54 | 1.72 | 2.1x |
| `grep WARN logs/big.log \| grep -m 3 timeout` | 100.14 | 58.31 | 1.7x |
| `grep ERROR logs/big.log \| cut -d' ' -f1 \| head -n 3` | 2.20 | 1.30 | 1.7x |

Full-scan throughput entries (`bench/stress/throughput`, informational): `wc -l < f` 2.9x, `cat f | wc -l` 2.8x, `head -c 300000000 /dev/zero | wc -c` 5.8x, `tr -d x < f | wc -c` 1.9x, `cut | sort | uniq -c` 1.6x, `seq 1 3000000 | tail -n 1` 1.04x, `grep -o 'status=[0-9]*' f | sort | uniq -c` 0.99x, `grep -v INFO f | wc -l` 0.84x. Fused stages share one thread, so a bash pipeline whose stages are both CPU bound can match or beat it on a multicore machine.

## Where the time went

- Process startup: a static musl executable with a size-class allocator and a C `main` (no std start code, no 256KB thread-local signal stack, lazy stack-limit raise) costs 0.30ms; bash costs 0.86ms. A page fault costs about 1.8us on this machine, so touched pages dominate.
- Pipelines: stages that are external commands, in-process utilities, or pure builtins (echo, printf, pwd, test, true, false) run in one fused pipeline without forking the shell. External stages are started with posix_spawn; in-process stages are fibers with a register-only context switch and non-blocking pipe I/O.
- Early exit: stage buffers are 8KB and a finished reader closes its pipe, so `grep | head` and `cat f | grep -m` stop within one buffer; `cat file | x` becomes `x < file`.
- Command substitution: simple pure builtins and fused pipelines run in-process; a body ending in an external command is captured through a pipe without forking the shell.
- grep stops at the first match per file when stdout is /dev/null.

## What remains

- git (1.27x), rg, and `grep -r` over thousands of files (about 1.0x): dominated by the child's own runtime or by per-file syscalls. In-process find, ls, sort, sed, rg, and git plumbing would remove the process cost.
- `grep -v` and `grep -o` emit lines slower than GNU grep.
- Forking constructs remain: subshells, compound commands in pipelines, background jobs, and builtins other than the pure set in a pipeline.
- `[[ =~ ]]` in the static build follows musl regex (no ERE back-references).
