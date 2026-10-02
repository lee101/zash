trap 'echo trap' USR1
( kill -USR1 $$ 2>/dev/null; echo after )
