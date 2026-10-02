set -u
( echo $undefined_var ) 2>&1
echo "status $?"
