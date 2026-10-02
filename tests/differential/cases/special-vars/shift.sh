set -- a b c d
shift
echo $@
shift 2
echo $@
shift 5 2>/dev/null
echo "status $?"
