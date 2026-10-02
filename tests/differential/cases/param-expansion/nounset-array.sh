set -u
a=(1 2)
( echo ${a[5]} ) 2>&1
echo "status $?"
