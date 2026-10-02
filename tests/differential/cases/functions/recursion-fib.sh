fib() { if (( $1 < 2 )); then echo $1; else echo $(( $(fib $(($1-1))) + $(fib $(($1-2))) )); fi; }
fib 15
