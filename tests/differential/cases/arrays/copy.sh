a=(x "y z" w)
b=("${a[@]}")
b[0]=changed
echo "${a[@]}" "|" "${b[@]}"
