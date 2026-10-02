touch ro.txt; chmod 444 ro.txt
( echo x > ro.txt ) 2>&1 | sed 's/^[^:]*: //' | head -1
