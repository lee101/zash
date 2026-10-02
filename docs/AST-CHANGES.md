# AST and parser requests from the interpreter workstream

Additive requests only. The interpreter works without them, each one closes a remaining differential case.

- `ast.Command`: add `arith_src: []const u8 = ""` holding the raw text between `((` and `))` for `(( expr ))` commands (xtrace prints `((  1 + 1  ))`, `declare -f` prints `(( x = 1 + 2 ))`). Same for the three clauses of `for (( ; ; ))` if cheap.
- Lexer: inside double quotes, `${x%%$'\n'*}` must treat `$'...'` in the pattern word as ANSI-C quoting (bash does). Case: command-subst/read-file.
- Lexer: unterminated heredoc should surface a warning (`line N: warning: here-document at line M delimited by end-of-file (wanted `EOF')`) on stderr, for example as an extra field on the parse result. Cases: heredoc/eof-unterminated, errors/syntax-unexpected-eof-heredoc.
- Parse errors: `a=(1 2` at EOF must print only the first line (`unexpected EOF while looking for matching `)'`) without the extra `syntax error: unexpected end of file`. Case: errors/syntax-array-literal.
- Syntax error inside `$( ... )` should report `PREFIX: command substitution: line N: syntax error near unexpected token `)'` plus the quoted source line, instead of `bad substitution`. Case: errors/syntax-in-cmdsubst.
- `Command.line` for a simple command whose words span several lines is the line of the last token in bash (LINENO and eval line numbers). Case: builtin-eval/line-numbers.
- Arithmetic parse errors at end of input: the error token is the last operator token (`1+` reports token `+`), currently empty.
- Lexer: `{CP[1]}>&-` and `{arr[0]}>file` (named fd redirection with an array element) must lex as `io_var` with name `CP[1]`. Case: jobs/coproc.
- Parser: `eval local D2B=($x)` inside a function body is a syntax error in zash but valid in bash (compound assignment words are accepted after `eval` and `time`). Works at top level, fails inside `f() { ... }`. Found with samples/pktgen/functions.sh from the kernel headers.
- Lexer: backslash-newline inside `$(( ... ))` must be removed before arithmetic parsing (kernel Documentation/arch/arm64/kasan-offsets.sh).
- AST: keep `${x}` distinguishable from `$x` (bash prints the original `${2}` in `ambiguous redirect` errors and in `declare -f`). For example a `braced: bool` on the variable part or a `.param` with an empty op.
- AST: add `Command.end_line: u32` (line of the last token). bash reports redirection errors on compound commands (`done > "$out"`), LINENO in multi-line command substitutions, and `eval` line numbers with the end line, not the start line.
