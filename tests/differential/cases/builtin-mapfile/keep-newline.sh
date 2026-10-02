mapfile a < a.txt
echo "${a[0]}" | od -c | head -1
