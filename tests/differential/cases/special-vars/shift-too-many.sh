set -- a
shift 3 2>&1 | sed 's/^[^:]*: //'
echo "status ${PIPESTATUS[0]}"
