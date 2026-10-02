# cat: control-flow
fib() { local a=0 b=1 i; for ((i=0;i<$1;i++)); do local t=$((a+b)); a=$b; b=$t; done; echo $a; }; fib 30
