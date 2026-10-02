for f in a.c b.h c.md d; do case $f in *.c|*.h) echo "$f code";; *.md) echo "$f doc";; *) echo "$f ?";; esac; done
