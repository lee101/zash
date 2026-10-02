# How the benchmark corpus distribution was derived

`bench/corpus/` is synthetic. No recorded command from any transcript appears in the repository. This file records the aggregate statistics the corpus was shaped to, and how they were obtained, without any raw commands.

## Source of the statistics

About 135,000 shell commands issued by coding agents through a Bash tool were analysed offline. Only counts left the analysis environment. The procedure:

1. Extract the command string of every Bash tool call from local agent transcripts.
2. Discard the transcript text entirely after tokenizing. Commands can contain secrets (tokens, URLs with credentials, hostnames), so nothing but aggregate counters was kept.
3. Split each command into pipeline stages with a shell-aware tokenizer (quotes, `$(...)`, heredocs and `&&`, `||`, `;`, `|` boundaries respected).
4. For each stage, take the first word after leading `VAR=value` assignments, strip any path prefix, and count it. Control-flow keywords (`if`, `for`, `while`, `case`) were counted as stages in their own right.
5. Per command, record booleans: contains a pipe, contains `&&`, contains a `for`/`while`/`until` loop, contains a heredoc.

## Aggregate results used

Stage frequency per 10,000 pipeline stages for the most common utilities:

| stage | per 10k |
|---|---|
| head | 800 |
| rg | 680 |
| echo | 570 |
| cd | 500 |
| tail | 410 |
| git | 400 |
| sed | 330 |
| cut | 310 |
| cat | 290 |
| ls | 225 |
| grep | 220 |
| wc | 65 |
| tr | 50 |
| sort | 30 |
| awk | 30 |

`if`, `for` and `while` control flow was common. `find`, `xargs`, `timeout`, `python3` one-liners, `curl` and `sleep` were present at lower rates.

Per-command shape rates: about 10% contain a pipe, 15% use `&&`, 8% contain a `for`/`while` loop, 4% contain a heredoc.

## How the corpus maps onto it

`scripts/gen-corpus.py` expands templates (deterministic, seeded) into `bench/corpus/NNN-category.sh`. It then runs every candidate under real bash against the fixture and drops entries that print nothing or differ between two bash runs, and trims to a runnable size. Resulting corpus: 638 entries (control-flow 190, text-pipeline 130, search 110, fs-listing 110, git 70, startup 28).

Deliberate deviations from the source distribution:

- **Pipes are over-sampled.** 55% of corpus entries contain a pipe (versus about 10% in the source). Most real agent commands are a single external program (a compiler, test runner or package manager) that no shell can speed up. The benchmark exists to measure the cases where an in-process shell can help, so the pipeline-shaped share is enriched. `&&` appears in 20% of entries, loops in 9%, heredocs in 4%.
- **`rg` is under-represented and constrained.** `rg` is multi-threaded and its output order is nondeterministic, so corpus entries use `--sort path`, a single file, or an order-insensitive reduction. Its share of stages is about 3% instead of 7%.
- **`head` is over-represented** relative to the source (21% of counted stages vs about 16% of the named stages above) because early-exit behaviour (`... | head -N`) is the most valuable optimization target.
- **Network and time sources are removed.** `curl` entries read `file://` URLs. `sleep` and `timeout` use tiny durations. Nothing depends on the clock, the pid or the machine.

Realised stage mix over the named utilities, per 10,000 counted stages: head 2145, echo 1189, wc 1059, ls 939, git 672, tail 629, grep 603, cd 474, sort 439, cat 370, rg 293, cut 250, find 233, sed 215, xargs 189, uniq 129, python3 60, tr 52, awk 26, curl 17, timeout 9, sleep 9. These are normalised over only the utilities listed, so they are not directly comparable to the table above.

## Refreshing the statistics

When a new batch of transcripts is analysed, update only the counts above (never paste commands), adjust the template weights and caps in `scripts/gen-corpus.py`, and regenerate with `scripts/gen-corpus.py`. The fixture it prunes against is built by `bench/fixture/gen.py`.
