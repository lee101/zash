declare -A m=([a]=1)
m+=([b]=2 [c]=3)
echo ${#m[@]}
