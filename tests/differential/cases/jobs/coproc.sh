coproc CP { cat; }
echo hello >&${CP[1]}
exec {CP[1]}>&-
read -r l <&${CP[0]}
echo $l
wait
