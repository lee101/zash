cnt=0
inc() { cnt=$((cnt+1)); }
inc; inc
echo $cnt
inc | cat
echo $cnt
