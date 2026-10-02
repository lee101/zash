t() { case $1 in a) return 0;; *) return 1;; esac; }
t a && echo yes
t b || echo no
