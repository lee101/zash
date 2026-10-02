echo() { printf 'fn\n'; }
command echo builtin
unset -f echo
