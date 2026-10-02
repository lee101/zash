readonly ro=1
read ro <<< x 2>&1 | sed 's/^[^:]*: //'
