set -C
echo a > nc.txt
echo b > nc.txt 2>/dev/null
echo "status $?"
