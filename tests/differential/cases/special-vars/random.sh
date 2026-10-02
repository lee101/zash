a=$RANDOM
b=$RANDOM
[ "$a" -ge 0 ] && [ "$a" -le 32767 ] && echo range
RANDOM=5; x=$RANDOM; RANDOM=5; y=$RANDOM; [ $x = $y ] && echo seeded
