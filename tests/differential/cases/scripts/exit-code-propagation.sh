run() { "$@"; local rc=$?; echo "rc=$rc"; return $rc; }
run true
run false || echo "caught"
run sh -c 'exit 7' || echo "caught $?"
