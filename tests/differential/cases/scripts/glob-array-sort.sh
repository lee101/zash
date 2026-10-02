files=(src/*)
echo ${#files[@]}
printf '%s\n' "${files[@]}" | sort -r
