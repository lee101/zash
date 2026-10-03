# cat: stress
grep ERROR logs/big.log | cut -d' ' -f1 | head -n 3
