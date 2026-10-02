x=val
cat <<EOF
x=$x ${x}y ${x:-d} $((1+2)) $(echo sub)
EOF
