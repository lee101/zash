[[ abc == a* ]] && echo glob
[[ abc == a?c ]] && echo q
[[ abc == "a*" ]] || echo quoted-literal
[[ abc == [a-c]bc ]] && echo class
