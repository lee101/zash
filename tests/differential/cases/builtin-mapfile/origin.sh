a=(x y)
mapfile -t -O 2 a < c.txt
echo ${#a[@]} ${a[2]}
