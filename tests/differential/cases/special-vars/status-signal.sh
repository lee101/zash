x=$(sh -c 'kill -9 $$'; echo $?)
echo "$x"
( sh -c 'kill -TERM $$' ) 2>/dev/null; echo $?
