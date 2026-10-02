unset 'a b' 2>&1 | sed 's/^[^:]*: //'
echo "status ${PIPESTATUS[0]}"
