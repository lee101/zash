# AST and parser changes made by the interpreter workstream

The parser workstream looked idle, so the interpreter workstream applied these small, additive fixes directly. Each one closes a differential case or a real script from a system scan.

- `ast.Command.end_line`: line of the last token of the command. Used for `eval` line numbers and for redirection errors on compound commands, matching bash.
- `ast.Command.src`: raw text between `((` and `))` for `(( expr ))` commands. Used for xtrace (`((  1 + 1  ))`) and `declare -f`.
- Parser: `eval` accepts compound assignment words (`eval local x=($y)`), as bash does.
- Lexer: `{name[idx]}>file` and `{name[idx]}>&-` lex as named fd redirections.
- Arithmetic parser: backslash-newline is whitespace.
- Lexer: unterminated heredocs record a warning (`Lexer.heredoc_warnings`) printed by the interpreter.
- Parse error: `a=(1 2` at end of input prints only the `unexpected EOF while looking for matching` line (bash behavior) and exits 1.

Known remaining differences worth a parser pass:

- `${x}` and `$x` produce the same AST part, so `ambiguous redirect` errors and `declare -f` print `$x`.
- Arithmetic parse error tokens: `1+` reports token `+` in bash. The interpreter patches this up from the expression text.
