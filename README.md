# kosm_toml

TOML for kosm: the `toml` adapter reads and writes `.toml` files (D105), such as alacritty's
config and vicinae's themes. Apps use it through `output.edit`, `output.generate` and
`output.block`; it knows no app (D1).

- **Paths:** every way TOML nests a key reaches the same path (D30). `[colors.primary]` with
  `background = ...`, `colors.primary.background = ...` and `colors = { primary = { background = ... } }`
  are all `colors.primary.background`, and a table spelled in several places is one table.
  A key holding a dot is a quoted segment: `"dim.foreground"` (D32).
- **Arrays of tables:** `[[keyboard.bindings]]` headers are one list, reached through
  `selection.elements` (D77, D80); a `[keyboard.bindings.x]` header below one belongs to its last
  element, as TOML says.
- **Values:** strings are written as basic strings (`"..."`), colors and joined values (D89) as
  strings too, `#rrggbb` by default. A float always keeps a `.` or an exponent (`13.0`), since
  `13` would be read back as an integer; `inf` and `nan` are written as TOML spells them. Booleans
  are only `true`/`false`, so `format.boolean` must stay `.true_false`. Lists and tables set by
  `edit` are written inline (`[1, 2]`, `{ x = 10 }`).
- **Whole files:** `generate` writes a table's own values first, then its tables as `[sections]`
  and its lists of tables as `[[arrays of tables]]`.
- **Reading:** the parser follows TOML 1.0 and reads TOML 1.1's inline tables across lines.
  Anything TOML rejects (a key defined twice, a table header repeated, an unquoted `yes`) is an
  error naming the line, and nothing is written.
- **Blocks:** `# kosm:begin <id>` comments.
