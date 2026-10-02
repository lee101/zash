declare -r r=1
declare +r r 2>&1 | sed 's/^[^:]*: //'
