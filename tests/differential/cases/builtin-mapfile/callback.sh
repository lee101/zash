cb() { echo "cb idx=$1 line=$2"; }
mapfile -t -C cb -c 1 a < b.txt
