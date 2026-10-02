IFS=,
read -ra a <<< "x,y,z"
echo ${#a[@]} ${a[1]}
