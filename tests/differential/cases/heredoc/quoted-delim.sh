x=val
cat <<'EOF'
$x `date` \n $(echo no)
EOF
