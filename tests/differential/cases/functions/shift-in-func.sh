f() { shift; echo "$@"; }
f a b c
set -- x y z
f 1 2
echo $@
