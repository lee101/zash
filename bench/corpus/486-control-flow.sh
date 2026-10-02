# cat: control-flow
mapfile -t lines < <(head -5 data/words.txt); echo ${#lines[@]}
