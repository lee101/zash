# cat: throughput
grep -o 'status=[0-9]*' logs/big.log | sort | uniq -c
