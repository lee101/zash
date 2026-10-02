mapfile -t -d : l <<< "a:b:c"
echo ${#l[@]} "${l[1]}"
