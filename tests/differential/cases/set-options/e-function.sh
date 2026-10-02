set -e
f() { echo before; false; echo after; }
f
echo never
