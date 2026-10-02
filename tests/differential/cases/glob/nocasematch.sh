shopt -s nocasematch
[[ ABC == abc ]] && echo m1
case ABC in abc) echo m2;; esac
