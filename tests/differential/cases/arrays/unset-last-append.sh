a=(a b c)
unset 'a[2]'
a+=(d)
echo ${!a[@]} ${a[@]}
