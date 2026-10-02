a=(1 2 3)
f() { local -n r=$1; echo "${r[@]}"; r+=(4); }
f a
echo "${a[@]}"
