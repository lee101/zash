# cat: control-flow
declare -A m=([a]=1 [b]=2); for k in a b; do echo $k=${m[$k]}; done
