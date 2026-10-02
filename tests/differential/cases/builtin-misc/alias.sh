shopt -s expand_aliases
alias ll='ls -1'
ll dir | head -2
alias ll
unalias ll
alias ll 2>&1 | sed 's/^[^:]*: //'
