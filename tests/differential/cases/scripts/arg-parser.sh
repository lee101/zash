usage() { echo "usage: $0 [-v] [-o out] files..." >&2; }
verbose=0; out=
while getopts "vo:" opt; do
  case $opt in v) verbose=1;; o) out=$OPTARG;; *) usage; exit 2;; esac
done
shift $((OPTIND-1))
echo "verbose=$verbose out=$out files=$*"
