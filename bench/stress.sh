#!/usr/bin/env bash
d="$(dirname "$(readlink -f "$0")")"
exec python3 "$d/run.py" --gen "$d/stress/gen.py" --fixture "$d/.stress" --corpus "${STRESS_CORPUS:-$d/stress/corpus}" --out "$d/results/stress" --no-startup "$@"
