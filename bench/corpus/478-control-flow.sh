# cat: control-flow
count() { ls "$1" | wc -l; }; count src; count docs
