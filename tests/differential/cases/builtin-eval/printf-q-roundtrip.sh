v="it's a \"test\" \$x"
eval "w=$(printf '%q' "$v")"
[ "$v" = "$w" ] && echo roundtrip
