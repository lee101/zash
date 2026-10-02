set -E
trap 'echo ERR' ERR
f() { false; echo after-false-in-f; }
f
