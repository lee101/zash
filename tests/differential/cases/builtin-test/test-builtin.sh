test -f a.txt && echo file
test 1 -lt 2 && echo lt
test "a" = "a" && echo eq
test -z "" && echo z
test; echo $?
