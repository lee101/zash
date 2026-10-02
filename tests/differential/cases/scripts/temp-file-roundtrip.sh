f=$(mktemp)
printf 'x\ny\n' > "$f"
wc -l < "$f" | tr -d ' '
rm -f "$f"
[ -e "$f" ] || echo removed
