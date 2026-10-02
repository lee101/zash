exec 3< a.txt
( read -r l <&3; echo "$l" )
read -r l <&3
echo "$l"
