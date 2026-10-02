# cat: control-flow
for i in 1 2 3 4 5 6; do [ $((i%2)) -eq 0 ] && continue; echo $i; done
