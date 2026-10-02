Synthetic agent-style commands, one per `NNN-category.sh`. Regenerate with `scripts/gen-corpus.py`.
Header lines: `# cat: <category>`, optional `# requires: <path relative to fixture>` (skipped when absent, e.g. logs/medium.log needs `FIXTURE_BIG=50m`).
Entries run with cwd at the fixture root, `$SCRATCH` is a writable temp dir, and must be idempotent and deterministic under bash.
