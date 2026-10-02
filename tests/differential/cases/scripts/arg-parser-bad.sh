usage() { echo usage; }
while getopts "vo:" opt; do
  case $opt in v) :;; o) :;; *) usage; exit 2;; esac
done 2>/dev/null
echo unreachable
