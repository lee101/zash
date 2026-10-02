# cat: control-flow
cat > $SCRATCH/s.sh <<'EOF'
echo from script
EOF
bash $SCRATCH/s.sh
