{ echo o1; echo e1 >&2; } &> both.txt
{ echo o2; echo e2 >&2; } &>> both.txt
sort both.txt
