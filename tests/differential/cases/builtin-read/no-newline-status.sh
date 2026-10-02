printf 'abc' | { read x; echo "status $? [$x]"; }
