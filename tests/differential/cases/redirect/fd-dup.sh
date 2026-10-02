exec 3>fd3.txt
echo to3 >&3
exec 3>&-
cat fd3.txt
