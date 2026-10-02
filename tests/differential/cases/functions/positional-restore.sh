set -- outer1 outer2
f() { echo "$1"; set -- inner; echo "$1"; }
f arg
echo $1
