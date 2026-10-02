declare -A m=([z]=1 [a]=2 [m]=3)
for k in "${!m[@]}"; do echo "$k=${m[$k]}"; done | sort
