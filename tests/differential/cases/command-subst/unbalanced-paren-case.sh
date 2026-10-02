x=$(echo a | while read l; do case $l in a) echo yes;; esac; done)
echo $x
