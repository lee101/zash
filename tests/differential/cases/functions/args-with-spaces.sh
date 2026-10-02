f() { for a in "$@"; do echo "[$a]"; done; }
f "a b" "c  d" ""
