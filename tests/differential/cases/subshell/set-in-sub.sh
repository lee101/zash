( set -e; false; echo no )
echo $?
set -e
( set +e; false; echo ok )
