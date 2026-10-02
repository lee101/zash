# cat: control-flow
cat <<'EOF' > $SCRATCH/h.txt
line1
line2
EOF
wc -l $SCRATCH/h.txt
