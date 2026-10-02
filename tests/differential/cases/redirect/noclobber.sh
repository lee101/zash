set -C
echo a > nc.txt
( echo b > nc.txt ) 2>&1 | sed 's/^[^:]*: //'
echo c >| nc.txt
cat nc.txt
