trap 'echo got-usr1' USR1
kill -USR1 $$
echo after
