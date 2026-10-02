export A=1 B=2 C
bash -c 'echo ${A} ${B} [${C-unset}]'
