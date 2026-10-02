x=$'a\tb\t\tc'
IFS=$'\t'
set -- $x
echo $#
