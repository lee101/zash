set -e
f() { false; echo in-f; }
if f; then echo cond-true; fi
