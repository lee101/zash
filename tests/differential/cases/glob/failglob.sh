cd globs
shopt -s failglob
( echo *.nomatch ) 2>&1
echo "status $?"
echo *.dat
