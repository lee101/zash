declare -A m=([n]=5)
(( m[n]++ ))
echo ${m[n]}
