printf 'a\n\nb\n' | { mapfile -t a; echo ${#a[@]}; }
