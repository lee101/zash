# cat: control-flow
for f in $(ls src/java/com/example/pkg02 | head -4); do echo "== $f"; head -2 src/java/com/example/pkg02/$f | cut -c1-30; done
