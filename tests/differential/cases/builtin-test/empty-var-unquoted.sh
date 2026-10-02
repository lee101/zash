v=
[ $v = x ] 2>&1 | sed 's/^[^:]*: //'
[ "$v" = x ] || echo quoted-ok
