set -- -b
while getopts "b:" o; do echo "o=$o"; done 2>&1 | sed 's/^[^:]*: //'
