# cat: control-flow
for f in README.md Makefile package.json; do case $f in *.md) echo doc;; *.json) echo json;; *) echo other;; esac; done
