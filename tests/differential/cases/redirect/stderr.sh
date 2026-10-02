ls nonexistent_xyz 2> err.txt
echo "status $?"
sed 's/^[^:]*: //' err.txt | head -1
