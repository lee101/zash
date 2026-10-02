[[ 1 -eq ]] 2>&1 | sed 's/^[^:]*: //' | head -1
echo "status ${PIPESTATUS[0]}"
