set -eE
trap 'echo ERR' ERR
f() { false; }
f
echo never
