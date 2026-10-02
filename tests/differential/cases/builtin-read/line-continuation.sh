printf 'a\\\nb\n' | { read x; echo "[$x]"; }
printf 'a\\\nb\n' | { read -r x; echo "[$x]"; }
