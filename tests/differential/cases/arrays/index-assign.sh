a=()
a[0]=x a[2]=z
echo ${#a[@]} ${!a[@]}
a[1]=y
echo ${a[@]}
