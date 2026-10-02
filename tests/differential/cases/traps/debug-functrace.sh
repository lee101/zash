f() { echo in-f; }
trap 'echo D' DEBUG
f
