PS3=
echo 1 | { select x in a b c; do echo "got $x"; break; done; } 2>/dev/null
