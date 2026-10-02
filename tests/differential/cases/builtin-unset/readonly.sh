readonly r=1
unset r 2>&1 | sed 's/^[^:]*: //'
echo "status ${PIPESTATUS[0]}"
