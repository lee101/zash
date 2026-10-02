printf 'a\nb\n' | { mapfile -t a; echo ${#a[@]}; }
echo ${#a[@]}
