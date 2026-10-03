# cat: stress
cat logs/big.log | tr -s ' ' | cut -d' ' -f1,2 | head -n 4
