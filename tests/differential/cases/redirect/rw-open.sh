echo data > rw.txt
exec 5<> rw.txt
read -r l <&5
echo "$l"
exec 5>&-
