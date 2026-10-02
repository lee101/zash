total=0
while read -r n; do total=$((total + n)); done < c.txt
echo $total
total=0
cat c.txt | while read -r n; do total=$((total + n)); done
echo $total
