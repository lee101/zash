declare -r r=1
echo $r
r=2 2>&1 | sed 's/^[^:]*: //'
echo $r
