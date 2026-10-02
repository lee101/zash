f() { for i in 1 2 3; do [ $i -eq 2 ] && return 9; done; }
f; echo $?
