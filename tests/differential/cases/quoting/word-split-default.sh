x="a  b	c
d"
set -- $x
echo $#
printf '<%s>\n' "$@"
