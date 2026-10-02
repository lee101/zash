mapfile -t a < b.txt
for l in "${a[@]}"; do echo "<$l>"; done
