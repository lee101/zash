while read -r a b; do echo "$b-$a"; done <<EOF
1 x
2 y
EOF
