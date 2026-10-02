re='('
[[ a =~ $re ]]
echo "status $?"
re='a{1'
[[ a =~ $re ]]
echo "status $?"
