# zash vs bash results

Harness: `bench/run.sh` (agent corpus, 630 entries, hyperfine `-N`, 20 runs, 3 warmup, median), `bench/stress.sh` (200MB log). Every entry is output-checked against bash before it is timed; speedup is bash median over zash median. Build: `zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseFast` (static musl executable). Machine: 32-core Linux VM under load, so single entries under about 2ms are noisy by 10 to 20 percent; category geomeans are stable to about 2 percent.

## Gate run after in-process sed, sort, uniq, ls, find and faster grep -v/-o

Agent corpus: 644 entries, all output-equal, geomean 2.62x (search 1.76x, text-pipeline 3.12x, fs-listing 3.07x, control-flow 3.35x, git 1.32x, startup 3.14x). Stress corpus: 14 of 14 output-equal, geomean 5.51x. Differential suite 1342/1342. `sort` and `ls` stay in-process only under C, POSIX or C.UTF-8 collation and fall back to the real tools in other locales, so locale-default machines see the old numbers for those two.

## Agent corpus, before and after

| category | entries | before geomean | after geomean | after median | zash median ms (before / after) |
|---|---|---|---|---|---|
| search | 110 | 1.12x | 1.62x | 1.23x | 4.80 / 3.63 |
| text-pipeline | 116 | 1.33x | 2.37x | 2.70x | 1.41 / 0.65 |
| fs-listing | 110 | 1.12x | 1.88x | 1.67x | 1.58 / 1.08 |
| control-flow | 190 | 1.42x | 2.56x | 2.53x | 1.39 / 0.70 |
| git | 70 | 1.05x | 1.28x | 1.26x | 2.70 / 2.09 |
| startup | 34 | 1.21x | 2.76x | 2.69x | 0.81 / 0.35 |
| all | 630 | 1.24x | 2.05x | | |

The 14 corpus entries that need `logs/huge.log` (`--big 50m,500m`) go from 0.85x to 2.75x geomean; the old figure includes `grep -c` entries where GNU grep stops at the first match because stdout is /dev/null.

Startup (`zash -c true` with a small environment): 0.77ms to 0.30ms, bash 0.86ms.

## Stress (200MB log, `bench/stress/corpus`)

Geomean 3.97x; all 14 entries output-equal and faster.

| entry | bash ms | zash ms | speedup |
|---|---|---|---|
| `cat logs/big.log \| grep -m 2 ERROR` | 70.00 | 0.68 | 103.7x |
| `cat logs/big.log \| head -n 3` | 4.84 | 0.50 | 9.8x |
| `grep -c ERROR logs/big.log > /dev/null` | 1.87 | 0.47 | 4.0x |
| `head -n 5 logs/big.log \| wc -l` | 1.86 | 0.49 | 3.8x |
| `cut -d' ' -f2 logs/big.log \| head -n 3` | 2.23 | 0.61 | 3.6x |
| `grep -m 3 ERROR logs/big.log` | 1.59 | 0.45 | 3.6x |
| `grep -m 1 ERROR logs/big.log \| cut -c1-20` | 1.93 | 0.62 | 3.1x |
| `grep ERROR logs/big.log \| head -n 5` | 1.99 | 0.68 | 2.9x |
| `tr a-z A-Z < logs/big.log \| head -n 2` | 2.00 | 0.71 | 2.8x |
| `tail -n 2 logs/big.log` | 1.36 | 0.50 | 2.7x |
| `yes \| head -n 1000000 \| wc -l` | 3.73 | 1.61 | 2.3x |
| `cat logs/big.log \| tr -s ' ' \| cut -d' ' -f1,2 \| head -n 4` | 2.28 | 1.02 | 2.2x |
| `grep ERROR logs/big.log \| cut -d' ' -f1 \| head -n 3` | 2.12 | 1.08 | 2.0x |
| `grep WARN logs/big.log \| grep -m 3 timeout` | 99.91 | 58.29 | 1.7x |

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
