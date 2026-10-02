# cat: control-flow
for d in src/*; do echo "$d $(ls $d | wc -l)"; done
