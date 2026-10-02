set -- a b c
IFS=,
echo "$*"
echo $*
IFS=
echo "$*"
