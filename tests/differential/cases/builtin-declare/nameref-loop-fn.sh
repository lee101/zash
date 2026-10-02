f() { local -n out=$1; out=set-by-f; }
f result
echo $result
