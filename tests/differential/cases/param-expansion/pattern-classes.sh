v=abc123def
echo ${v#[a-z]} ${v##[a-z]*[0-9]} ${v%[a-z]} ${v%%[0-9]*}
