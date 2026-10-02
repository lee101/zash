counter=0
inc() { counter=$((counter+1)); }
twice() { "$@"; "$@"; }
twice inc
echo $counter
