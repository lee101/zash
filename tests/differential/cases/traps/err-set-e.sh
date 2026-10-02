set -e
trap 'echo "ERR trap"' ERR
false
echo never
