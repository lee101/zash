set -e
trap 'echo "failed at line $LINENO"' ERR
echo start
false
echo unreachable
