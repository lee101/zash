declare -A rows
rows[0]="a b c"
rows[1]="d e f"
for r in 0 1; do set -- ${rows[$r]}; echo "row $r: $# items, second=$2"; done
