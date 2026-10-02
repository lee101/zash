exec 3>&1 >dup.txt
echo to-file
echo to-term >&3
exec 1>&3 3>&-
cat dup.txt
