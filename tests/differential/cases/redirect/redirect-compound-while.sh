i=0
while [ $i -lt 3 ]; do echo $i; i=$((i+1)); done > w.txt
tr '\n' ' ' < w.txt; echo
