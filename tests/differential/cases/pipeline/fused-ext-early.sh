seq 1 1000000 | head -n 2
echo "st=${PIPESTATUS[*]}"
yes | head -n 2
echo "st=${PIPESTATUS[*]}"
seq 1 1000000 | tail -n 1
seq 1 200000 | grep -m 1 99 | cat
