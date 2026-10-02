unset u
[[ -n $u && $u == x ]] || echo short
[[ -z $u || $u == x ]] && echo short2
