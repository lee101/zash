# cat: control-flow
for f in tests/unit00/*; do head -1 "$f" | cut -c1-30; done | sort | uniq -c | sort -rn | head -3
