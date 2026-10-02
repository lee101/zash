f() { :; }
readonly -f f
f() { echo changed; } 2>&1 | sed 's/^[^:]*: //'
