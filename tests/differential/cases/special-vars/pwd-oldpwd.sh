cd dir
cd ..
[ "$OLDPWD" != "$PWD" ] && echo differ
echo ${PWD##*/} | grep -c work
