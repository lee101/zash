cmd='echo $((1+2))'
eval "$cmd"
x=5
eval "y=$x"
echo $y
