printf 'a\\b\n' | while read -r l; do echo "$l"; done
printf 'a\\b\n' | while read l; do echo "$l"; done
