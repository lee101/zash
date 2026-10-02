f() { echo "${FUNCNAME[@]}"; }
g() { f; }
g
