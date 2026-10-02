set -- -m "a message"
getopts "m:" o
echo "[$OPTARG]"
