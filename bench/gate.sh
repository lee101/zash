#!/usr/bin/env bash
set -u
d="$(dirname "$(readlink -f "$0")")"
rc=0
echo "stress corpus: every entry output-equal and at least ${GATE_STRESS_MIN:-1.1}x faster than bash"
"$d/stress.sh" --runs "${GATE_RUNS:-10}" --min-speedup "${GATE_STRESS_MIN:-1.1}" || rc=1
echo "agent corpus: output-equal, geomean at least ${GATE_GEOMEAN_MIN:-1.6}x, every category at least ${GATE_CATEGORY_MIN:-1.05}x"
"$d/run.sh" --runs "${GATE_RUNS:-10}" --out "$d/results/gate" --min-geomean "${GATE_GEOMEAN_MIN:-1.6}" --min-category-geomean "${GATE_CATEGORY_MIN:-1.05}" || rc=1
[ $rc -eq 0 ] && echo "gate: pass" || echo "gate: FAIL"
exit $rc
