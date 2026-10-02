exec 4< a.txt
read -r l <&4
echo "$l"
read -r l <&4
echo "$l"
exec 4<&-
