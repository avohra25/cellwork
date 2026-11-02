# cellwork

A spreadsheet engine in Erlang/OTP: a formula language with spreadsheet
semantics, an evaluator, and incremental recalculation over a dependency
graph. Work in progress.

This first cut has the formula front end:

- **A1 references** (`B3`, `$A$1`, `AA10`) with the usual grid limits
  (`A`..`XFD`, rows 1..1048576).
- **Lexer and parser** generated with `leex` and `yecc`, using spreadsheet
  operator precedence: comparison < `&` < `+ -` < `* /` < `^` < unary
  minus < postfix `%` (so `-2^2` is `4`).
- **Pretty-printer** that emits minimal parentheses and round-trips
  through the parser (checked on thousands of random formulas).
- **Dependency extraction** and **relative-reference shifting** for
  copy/paste (`$` parts stay fixed, references pushed off the grid become
  `#REF!`).

```sh
rebar3 eunit
```

MIT licensed.
