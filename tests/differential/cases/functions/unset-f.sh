f() { echo hi; }
unset -f f
f 2>&1 | sed 's/^[^:]*: //'
echo $?
