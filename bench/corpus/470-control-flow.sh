# cat: control-flow
if [ "$(wc -l < README.md)" -gt 2 ]; then echo long; else echo short; fi
