mapfile -t 1x < a.txt 2>&1 | sed 's/^[^:]*: //'
