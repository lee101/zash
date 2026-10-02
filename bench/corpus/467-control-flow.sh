# cat: control-flow
c=0; while read -r l; do c=$((c+1)); done < data/words.txt; echo $c
