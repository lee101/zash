seq 1 400000 | tr 0 1 | sort | tail -n 1
echo "st=${PIPESTATUS[*]}"
seq 1 200000 | cat | sort -n | cat | tail -n 2
seq 1 100000 | head -n 3 | sort
echo "st=${PIPESTATUS[*]}"
yes | head -n 3 | sort | uniq -c
