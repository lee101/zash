# cat: control-flow
cat > $SCRATCH/n2.txt <<'EOF'
alpha 2
beta
EOF
grep -c a $SCRATCH/n2.txt
