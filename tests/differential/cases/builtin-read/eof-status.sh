read x < /dev/null
echo "status $?"
read x <<< ""
echo "status $?"
