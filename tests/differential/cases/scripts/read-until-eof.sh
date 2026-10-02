count=0
while IFS= read -r line; do count=$((count+1)); done
echo "lines=$count"
