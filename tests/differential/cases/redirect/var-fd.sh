exec {fd}> vf.txt
echo via-var >&$fd
exec {fd}>&-
cat vf.txt
