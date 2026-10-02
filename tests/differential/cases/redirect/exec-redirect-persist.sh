exec 3< a.txt
head -1 <&3
head -1 <&3
exec 3<&-
