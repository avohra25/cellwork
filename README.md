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
- **Incremental recalculation** (`cell_sheet`, purely functional): the
  sheet keeps each formula's precedents and a reverse index of
  dependents. An edit recalculates only the edited cells and their
  transitive dependents, in an order found by Tarjan's strongly connected
  components algorithm, which doubles as cycle detection: every cell on a
  circular reference becomes `#CYCLE!` and recovers as soon as the cycle
  is broken. Edits return exactly the cells whose value changed, batches
  are atomic (one bad formula and nothing changes), and copy/paste shifts
  relative references.
- **Dependency extraction** and **relative-reference shifting** for
  copy/paste (`$` parts stay fixed, references pushed off the grid become
  `#REF!`).

```erlang
{ok, S1, _} = cell_sheet:set_many(cell_sheet:new(),
                                  [{"A1", "10"}, {"A2", "=A1*2"}, {"A3", "=SUM(A1:A2)"}]),
{ok, S2, Changed} = cell_sheet:set(S1, "A1", "5"),
%% Changed = [{{1,1},5.0}, {{1,2},10.0}, {{1,3},15.0}]
<<"15">> = cell_sheet:display(S2, "A3").
```

Tests include randomized differential checks: after hundreds of random
edit sequences the incremental sheet must match a fresh sheet built from
the final inputs, a full recalculation, and (on acyclic sheets) a naive
recursive evaluator, and the reported changes must be exactly right.

```sh
rebar3 eunit
```

MIT licensed.
