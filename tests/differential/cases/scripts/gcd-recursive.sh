gcd() { if (( $2 == 0 )); then echo $1; else gcd $2 $(( $1 % $2 )); fi; }
gcd 48 18
gcd 17 5
