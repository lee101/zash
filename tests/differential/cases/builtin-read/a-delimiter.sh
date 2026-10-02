IFS=, read -ra f <<< "a,b,,c"
echo ${#f[@]}
