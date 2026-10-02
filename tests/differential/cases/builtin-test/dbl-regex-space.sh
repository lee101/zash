re='a b'
[[ "a b" =~ $re ]] && echo spaced
[[ "a b" =~ a\ b ]] && echo escaped
