unset v
( echo "${v:?custom message}" ) 2>&1
echo "status $?"
( echo "${v?}" ) 2>&1
echo "status $?"
