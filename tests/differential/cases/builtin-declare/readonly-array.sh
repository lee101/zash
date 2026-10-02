declare -ra a=(1 2)
a+=(3) 2>&1 | sed 's/^[^:]*: //'
echo ${a[@]}
