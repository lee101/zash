n=$(wc -l < a.txt)
echo $n
n=$(wc -l < a.txt | tr -d ' ')
echo $((n+1))
