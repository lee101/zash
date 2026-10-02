v=
[[ $v == "" ]] && echo empty
[[ -z $v ]] && echo z
[[ $v ]] || echo falsy
v=x
[[ $v ]] && echo truthy
