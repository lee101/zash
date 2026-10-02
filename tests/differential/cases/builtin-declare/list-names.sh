declare -i i1=1
declare -r r1=1
declare -p | grep -E '^declare -[ir]+ (i1|r1)=' | sort
