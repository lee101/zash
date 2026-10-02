a=([5]=five [10]=ten)
echo ${!a[@]} ${#a[@]}
a+=(x)
echo ${!a[@]}
