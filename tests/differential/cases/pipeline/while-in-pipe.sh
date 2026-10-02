seq 1 5 | while read -r n; do echo $((n*n)); done | paste -sd+
