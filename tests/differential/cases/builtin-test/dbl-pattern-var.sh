p='a*'
[[ abc == $p ]] && echo unquoted-pattern
[[ abc == "$p" ]] || echo quoted-literal
