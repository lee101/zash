[[ a.txt -ef link.txt ]] && echo same
[[ a.txt -nt nonexistent ]] && echo newer-than-missing
