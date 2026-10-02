# cat: control-flow
cat > $SCRATCH/n1.txt <<'EOF'
alpha 1
beta
EOF
grep -c a $SCRATCH/n1.txt
