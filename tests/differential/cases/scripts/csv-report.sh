tail -n +2 data.csv | while IFS=, read -r id name score; do
  printf '%-5s %3d\n' "$name" "$score"
done
echo ---
tail -n +2 data.csv | cut -d, -f3 | sort -n | tail -1
