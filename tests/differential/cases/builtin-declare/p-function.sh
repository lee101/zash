f() { echo hi; }
declare -pf f 2>/dev/null || declare -f f
