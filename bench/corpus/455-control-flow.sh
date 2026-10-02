# cat: control-flow
for f in $(ls src/js/comp02 | head -4); do echo "== $f"; head -2 src/js/comp02/$f | cut -c1-30; done
