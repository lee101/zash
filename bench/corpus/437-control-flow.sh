# cat: control-flow
for f in tests/unit00/*; do [ -s "$f" ] && echo "$f"; done | wc -l
