x=1
declare -n r=x
[ -R r ] && echo nameref
