f() { echo "$*"; IFS=,; echo "$*"; }
f a b c
