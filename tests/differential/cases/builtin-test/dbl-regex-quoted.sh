[[ "a.c" =~ "a.c" ]] && echo lit
[[ "abc" =~ "a.c" ]] || echo quoted-no-regex
re='a.c'
[[ abc =~ $re ]] && echo var-regex
