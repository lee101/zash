echo $(cat a.txt | sort -r | head -2)
echo "$(cat a.txt | tr a-z A-Z | tail -1)"
