trap 'echo ERR' ERR
if false; then :; fi
false || true
false && true
echo reached
