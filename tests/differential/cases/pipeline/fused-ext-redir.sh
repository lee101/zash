seq 1 5 > out1.txt | cat; echo "st=${PIPESTATUS[*]}"; wc -l < out1.txt
seq 1 5 | cat > out2.txt; wc -l < out2.txt
seq 1 3 | sort -r 2>&1 | cat -n
seq 1 3 | sort -r > /dev/null; echo "st=${PIPESTATUS[*]}"
cat < out1.txt | sort -r | head -n 2
head -n 2 < out1.txt | sort -r
seq 1 4 | /bin/cat - | tail -n 1
