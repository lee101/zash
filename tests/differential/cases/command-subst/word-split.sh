set -- $(echo a b   c)
echo $#
set -- "$(echo a b   c)"
echo $#
