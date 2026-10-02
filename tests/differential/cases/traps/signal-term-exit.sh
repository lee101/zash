trap 'echo cleanup' EXIT
trap 'echo term; exit 2' TERM
kill -TERM $$
echo never
