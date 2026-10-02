# AST and parser requests from the interpreter workstream

Additive requests only. The interpreter works without them, each one closes a remaining differential case.

- `ast.Command`: add `arith_src: []const u8 = ""` holding the raw text between `((` and `))` for `(( expr ))` commands (xtrace prints `((  1 + 1  ))`, `declare -f` prints `(( x = 1 + 2 ))`). Same for the three clauses of `for (( ; ; ))` if cheap.
- Lexer: inside double quotes, `${x%%$'\n'*}` must treat `$'...'` in the pattern word as ANSI-C quoting (bash does). Case: command-subst/read-file.
- Lexer: unterminated heredoc should surface a warning (`line N: warning: here-document at line M delimited by end-of-file (wanted `EOF')`) on stderr, for example as an extra field on the parse result. Cases: heredoc/eof-unterminated, errors/syntax-unexpected-eof-heredoc.
- Parse errors: `a=(1 2` at EOF must print only the first line (`unexpected EOF while looking for matching `)'`) without the extra `syntax error: unexpected end of file`. Case: errors/syntax-array-literal.
- Syntax error inside `$( ... )` should report `PREFIX: command substitution: line N: syntax error near unexpected token `)'` plus the quoted source line, instead of `bad substitution`. Case: errors/syntax-in-cmdsubst.
- `Command.line` for a simple command whose words span several lines is the line of the last token in bash (LINENO and eval line numbers). Case: builtin-eval/line-numbers.
- Arithmetic parse errors at end of input: the error token is the last operator token (`1+` reports token `+`), currently empty.
