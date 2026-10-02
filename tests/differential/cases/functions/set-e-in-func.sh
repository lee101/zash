set -e
f() { false; echo not-reached; }
f || echo handled
