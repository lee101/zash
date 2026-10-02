set -e
case $- in *e*) echo has-e;; esac
set +e
case $- in *e*) echo has-e;; *) echo no-e;; esac
