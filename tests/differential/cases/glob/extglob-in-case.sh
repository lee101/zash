shopt -s extglob
for s in aab b ab c; do case $s in +(a)b) echo "$s: a+b";; @(b|c)) echo "$s: b|c";; *) echo "$s: other";; esac; done
