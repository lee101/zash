# cat: control-flow
for f in $(ls tests/unit00 | head -4); do echo "== $f"; head -2 tests/unit00/$f | cut -c1-30; done
