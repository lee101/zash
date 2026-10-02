readonly R=1
echo $R
R=2 2>&1 | sed 's/^[^:]*: //'
echo $?
