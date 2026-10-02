cd globs
shopt -s nullglob
echo *.nomatch
echo "[$(echo *.nomatch)]"
set -- *.nomatch
echo $#
