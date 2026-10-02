trap 'echo hup' 1
kill -HUP $$
echo after
