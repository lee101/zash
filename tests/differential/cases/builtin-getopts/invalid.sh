set -- -z
while getopts "ab" o; do echo "o=$o"; done 2>&1 | sed 's/^[^:]*: //'
