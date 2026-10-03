# cat: throughput
cut -d' ' -f2 logs/big.log | sort | uniq -c
