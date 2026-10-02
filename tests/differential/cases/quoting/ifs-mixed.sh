IFS=' :'
x="a : b  c"
set -- $x
printf '<%s>\n' "$@"
