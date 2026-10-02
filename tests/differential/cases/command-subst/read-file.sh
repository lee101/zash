x=$(<a.txt)
echo "$x"
y=$(< b.txt)
echo "${y%%$'\n'*}"
