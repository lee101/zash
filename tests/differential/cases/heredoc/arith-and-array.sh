a=(x y z)
cat <<EOF
${a[1]} ${#a[@]} ${a[*]}
EOF
