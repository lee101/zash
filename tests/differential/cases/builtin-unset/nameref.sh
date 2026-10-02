x=1
declare -n r=x
unset r
echo "[$x] [${r-unset}]"
