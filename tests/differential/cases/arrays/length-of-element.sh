a=(abc de f)
for i in "${!a[@]}"; do echo "$i ${#a[$i]}"; done
