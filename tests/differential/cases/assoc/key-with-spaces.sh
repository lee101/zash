declare -A m
m["a b"]=1
m[c]=2
echo ${m["a b"]} ${#m[@]}
