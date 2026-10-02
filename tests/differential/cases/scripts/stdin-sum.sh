sum=0
while read -r n; do
  [[ $n =~ ^-?[0-9]+$ ]] || { echo "skip: $n"; continue; }
  sum=$((sum+n))
done
echo "sum=$sum"
