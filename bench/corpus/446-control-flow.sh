# cat: control-flow
for f in src/java/com/example/pkg02/*; do echo "${f##*/}"; done | head -3
