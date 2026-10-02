a=(banana apple cherry)
printf '%s\n' "${a[@]}" | sort
sorted=($(printf '%s\n' "${a[@]}" | sort))
echo "${sorted[@]}"
