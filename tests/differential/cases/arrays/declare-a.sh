declare -a a
a[3]=x
echo ${#a[@]} ${!a[@]}
declare -a b=(1 2 3)
echo "${b[@]}"
