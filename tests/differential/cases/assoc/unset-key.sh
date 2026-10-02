declare -A m=([a]=1 [b]=2)
unset 'm[a]'
echo ${#m[@]} ${m[b]} "[${m[a]}]"
