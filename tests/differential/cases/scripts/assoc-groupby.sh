declare -A groups
while IFS=, read -r id name score; do
  groups[$score]+="$name "
done < <(tail -n +2 data.csv)
for k in $(printf '%s\n' "${!groups[@]}" | sort -n); do echo "$k: ${groups[$k]}"; done
