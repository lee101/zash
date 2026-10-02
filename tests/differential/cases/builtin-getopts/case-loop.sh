set -- -v -f out.txt -h
while getopts "vf:h" o; do
  case $o in
    v) echo verbose;;
    f) echo "file=$OPTARG";;
    h) echo help;;
  esac
done
