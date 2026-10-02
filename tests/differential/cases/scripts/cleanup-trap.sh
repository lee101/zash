tmp=$(mktemp -d)
trap 'rm -rf "$tmp"; echo cleaned' EXIT
echo data > "$tmp/f"
[ -f "$tmp/f" ] && echo created
