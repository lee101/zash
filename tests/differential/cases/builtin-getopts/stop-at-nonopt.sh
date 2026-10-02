set -- -a file -b
while getopts "ab" o; do echo $o; done
echo "OPTIND=$OPTIND"
