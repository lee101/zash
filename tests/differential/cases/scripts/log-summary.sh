cat > app.log <<'EOF'
2025-01-01 INFO start
2025-01-01 ERROR disk full
2025-01-02 WARN slow
2025-01-02 ERROR timeout
2025-01-03 INFO stop
EOF
echo "errors: $(grep -c ERROR app.log)"
grep ERROR app.log | cut -d' ' -f1 | sort -u
awk '{c[$2]++} END {for (k in c) print k, c[k]}' app.log | sort
