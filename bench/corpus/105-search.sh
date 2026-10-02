# cat: search
fd_missing() { command -v fd >/dev/null; }; fd_missing || find . -maxdepth 1 -name '*.md' | sort
