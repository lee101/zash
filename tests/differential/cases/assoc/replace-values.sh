declare -A m=([a]=foo [b]=bar)
echo ${m[a]/o/0} ${m[b]^^}
