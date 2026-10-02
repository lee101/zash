f() { local -a l=("$@"); echo ${#l[@]} "${l[1]}"; }
f a "b c" d
