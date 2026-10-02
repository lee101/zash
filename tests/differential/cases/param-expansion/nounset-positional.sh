set -u
( echo $1 ) 2>&1
echo "status $?"
echo ${1:-none}
