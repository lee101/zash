c=0
while read -r l; do c=$((c+1)); done < <(seq 1 5)
echo $c
