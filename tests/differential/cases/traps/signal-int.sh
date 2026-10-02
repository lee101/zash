trap 'echo got-int' INT
kill -INT $$
echo after
