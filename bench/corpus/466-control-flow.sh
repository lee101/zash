# cat: control-flow
while IFS=, read -r id name email age cc; do [ "$age" -gt 78 ] && echo "$name"; done < <(head -500 data/users.csv | tail -n +2) | head -5
