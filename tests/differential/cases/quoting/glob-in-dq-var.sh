cd globs
p='*.dat'
echo "$p"
echo $p | tr ' ' '\n' | sort | head -3
