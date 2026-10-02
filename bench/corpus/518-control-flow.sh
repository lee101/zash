# cat: control-flow
local_test() { local x=1; echo $x; }; x=2; local_test; echo $x
