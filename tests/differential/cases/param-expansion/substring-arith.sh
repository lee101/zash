v=abcdefgh
n=2
echo ${v:n} ${v:n+1:n*2} ${v:$((n-1)):1}
