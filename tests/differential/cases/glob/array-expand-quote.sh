cd globs
a=(*.dat)
echo "${#a[@]}"
for f in *.dat; do echo "[$f]"; done
