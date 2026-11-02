# cellwork

A spreadsheet engine in Erlang/OTP: a formula language with spreadsheet
semantics, an evaluator, and incremental recalculation over a dependency
graph. Work in progress.

So far:

- **A1 references** (`B3`, `$A$1`, `AA10`) with the usual grid limits
  (`A`..`XFD`, rows 1..1048576).
- **Lexer and parser** generated with `leex` and `yecc`, using spreadsheet
  operator precedence: comparison < `&` < `+ -` < `* /` < `^` < unary
  minus < postfix `%` (so `-2^2` is `4`).
- **Pretty-printer** that emits minimal parentheses and round-trips
  through the parser (checked on thousands of random formulas).
- **Evaluator** with spreadsheet semantics: IEEE-double numbers shown
  General-style (`0.1+0.2` shows `0.3`), text that looks numeric coerces
  in arithmetic, blanks act as zero or empty text, comparisons order
  numbers < text < booleans with case-insensitive text, and error values
  (`#DIV/0!`, `#VALUE!`, `#REF!`, `#NAME?`, `#NUM!`, `#N/A`) propagate.
- **29 built-in functions**: `SUM`, `PRODUCT`, `AVERAGE`, `MIN`, `MAX`,
  `COUNT`, `COUNTA`, `COUNTIF`, `SUMIF` (criteria like `">=10"`,
  `"<>done"`, `"ap*"` with `*`/`?` wildcards), lazy `IF` and `IFERROR`,
  `ISERROR`, `ISBLANK`, `ISNUMBER`, `ISTEXT`, `AND`, `OR`, `NOT`, `ABS`,
  `INT`, `SQRT`, `POWER`, `MOD`, `ROUND`, `CONCAT`, `LEN`, `UPPER`,
  `LOWER`, `TRIM`. Aggregates skip text and booleans read from cells but
  coerce arguments written directly, like the real thing.
- **Dependency extraction** and **relative-reference shifting** for
  copy/paste (`$` parts stay fixed, references pushed off the grid become
  `#REF!`).

```sh
rebar3 eunit
```

MIT licensed.
