# cat: control-flow
for f in $(ls src/rs/crate03/src | head -4); do echo "== $f"; head -2 src/rs/crate03/src/$f | cut -c1-30; done
