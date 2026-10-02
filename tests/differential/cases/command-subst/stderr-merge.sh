x=$(echo out; echo err >&2 2>&1) 2>&1
echo "[$x]"
