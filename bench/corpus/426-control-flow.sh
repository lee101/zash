# cat: control-flow
for f in $(ls data/small | head -4); do echo "== $f"; head -2 data/small/$f | cut -c1-30; done
