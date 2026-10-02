trap 'echo parent-usr1' USR1
( trap -p USR1 | wc -l )
