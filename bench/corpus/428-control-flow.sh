# cat: control-flow
for f in data/small/*; do b=${f##*/}; echo "${b%.*}"; done | head -3
