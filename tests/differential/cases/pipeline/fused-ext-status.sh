/bin/false | cat; echo "st=${PIPESTATUS[*]}"
cat nonexistent-file 2>&1 | head -n 1; echo "st=${PIPESTATUS[*]}"
ls nonexistent-dir 2>/dev/null | wc -l; echo "st=${PIPESTATUS[*]}"
set -o pipefail
seq 1 3 | /bin/false | cat; echo "pf=$?"
seq 1 3 | sort -r | /bin/false; echo "pf=$?"
printf 'b\na\n' | sort | grep -c a
