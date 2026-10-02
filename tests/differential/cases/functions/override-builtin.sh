echo() { printf 'custom: %s\n' "$*"; }
echo hi
builtin echo real
unset -f echo
echo back
