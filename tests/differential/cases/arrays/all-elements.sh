a=(a "b c" d)
printf '<%s>' "${a[@]}"; echo
printf '<%s>' "${a[*]}"; echo
printf '<%s>' ${a[@]}; echo
