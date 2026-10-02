TIMEFORMAT='%R'
x=$( { time true; } 2>&1 )
echo "${x//[0-9.]/}"
