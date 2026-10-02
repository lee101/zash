{ echo out; echo err >&2; } 2>&1 >/dev/null
echo ---
{ echo out; echo err >&2; } >/dev/null 2>&1
echo done
