printf 'a\0b\0c\0' | while IFS= read -r -d '' x; do echo "[$x]"; done
