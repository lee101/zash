shopt -s extglob
[[ foo.txt == !(*.log) ]] && echo notlog
[[ foo.log == !(*.log) ]] || echo islog
