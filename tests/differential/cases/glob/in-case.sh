f=file.txt
case $f in *.txt) echo text;; *) echo other;; esac
case $f in f??e.*) echo m;; esac
case x in [a-c]) echo abc;; [x-z]) echo xyz;; esac
