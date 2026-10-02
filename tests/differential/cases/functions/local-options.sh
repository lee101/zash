f() { local -i n=5; n+=2; echo $n; local -r r=ro; echo $r; }
f
