# cat: control-flow
for f in $(ls src/ts/svc01 | head -4); do echo "== $f"; head -2 src/ts/svc01/$f | cut -c1-30; done
