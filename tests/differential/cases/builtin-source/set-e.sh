echo 'false; echo after-false' > se.sh
set -e
. ./se.sh
echo not-reached
