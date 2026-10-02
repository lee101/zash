v=5
declare -i v
v=v+1
echo $v
declare +i v
v=v+1
echo $v
