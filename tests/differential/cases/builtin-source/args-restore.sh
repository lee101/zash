set -- orig
echo 'echo "in: $1"' > s.sh
. ./s.sh arg
echo "out: $1"
