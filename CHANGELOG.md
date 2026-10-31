# Changelog

All notable changes to yamleam are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.4.0] — wrapped values

### Added

- Plain scalars may continue on the lines below them, as hand-written YAML such as OpenAPI descriptions does (YAML 1.2 §7.3.3). The lines join with a space, and each empty line between them becomes a newline. In block context a continuation line must be indented more than the value's key, or its dash for a sequence item, so a sibling key never reads as part of the value. A comment or a document marker ends the value.
- Single-quoted strings may span lines, folding as double-quoted strings do.
- A `:` after a plain scalar that spans lines is a `ParseError` at the `:`, because a mapping key must fit on one line (`a` then `b: c` on the next line used to be rejected with a vaguer error).
- The README and the package page link to [Enverium](https://enverium.com), which builds and maintains yamleam.

### Fixed

- A plain scalar that wraps inside a flow collection is one value, as YAML 1.2 specifies. `[a` followed by `b]` on the next line used to read as two items, `["a", "b"]`; it now reads as `["a b"]`.

## [1.3.0] — JavaScript target, decode error detail

### Added

- The JavaScript target is supported and tested. yamleam has always been pure Gleam; the full test suite now runs on both targets, with no npm dependency.

### Fixed

- On JavaScript, a float literal that overflows (`2.5E500`) resolves to a string, as it does on Erlang, instead of to `Infinity`.

### Changed

- `error.to_string` describes a `DecodeError` by the decoder's own report: the path, the expected and the found type of the first error, and how many more there are (`yaml decode error at spec.port: expected Int, found String`). It used to print only "could not extract requested shape".

## [1.2.0] — multi-line flow collections, JSON documents

### Added

- Flow collections may span several lines. `[` and `{` open on one line and close on a later one, with comments and blank lines allowed in between. Every token keeps its own position, so errors inside the collection point at their own line.
- JSON documents parse as YAML 1.2 intends, whether pretty-printed or compact. Inside flow context, a `:` directly after a quoted key or a closed collection is a value indicator even with no space after it (`{"a":1}`).
- `\u` escapes combine UTF-16 surrogate pairs (`\ud83d\ude00` is 😀), as JSON writes characters past U+FFFF. A lone surrogate is still a `ParseError`.

### Changed

- Flow-mapping errors for duplicate keys and a missing `:` report the key's own line and column.
- A `---` or `...` line inside an open flow collection is a `ParseError`.

## [1.1.0] — compact sequences, complete escapes

### Added

- Compact block sequences. A sequence that is a mapping value may put its dashes at the key's own column (`steps:` followed by `- run: make`), the style kubectl, GitHub Actions and Ansible tooling emit (YAML 1.2 §8.2.1). This works at every nesting level, inside `- key:` sequence items, and after an anchor.
- The full YAML 1.2 double-quoted escape set: `\a`, `\b`, `\e`, `\f`, `\v`, `\N`, `\_`, `\L`, `\P`, escaped space and tab, `\xXX`, `\uXXXX` and `\UXXXXXXXX`, alongside the existing `\0`, `\t`, `\n`, `\r`, `\"`, `\/` and `\\`.

### Fixed

- An unknown escape in a double-quoted string (`"\q"`), a short hex escape, or an escape naming a surrogate now returns a `ParseError` at the backslash. Previously the backslash was dropped and the letter kept, so `"caf\u00e9"` read as `cafu00e9`.
- Double-quoted strings that span lines now fold as YAML 1.2 specifies. Trailing white space before a break is dropped, each empty line becomes a newline, and a `\` at the end of a line joins the lines with no space.
- CRLF and CR line endings read the same as LF. Before this, a file saved with Windows line endings failed as soon as a key had a nested value. Block scalar and folded string content uses `\n`, as YAML 1.2 specifies.
- A leading UTF-8 byte order mark is dropped. Previously it became part of the first key.

### Changed

- The `Unsupported` feature text for tags is now `tags ('!type')`, without a release reference.
- `gleam.toml` now declares the real minimums: Gleam `>= 1.9.0` and `gleam_stdlib >= 0.60.0`. The decoder layer has used `gleam_stdlib` 0.60 APIs since 1.0, so the old `>= 0.46.0` bound could resolve to versions that don't compile. With the corrected bounds, the resolver reports the mismatch instead.
- Development uses Gleam 1.19.2 and Erlang/OTP 29.1.2, pinned in `.tool-versions`.
- Rewrote the README, ROADMAP and module documentation. The README now covers usage, a grouped feature reference and a scalar resolution table, and its examples are compiled and run by the test suite.

## [1.0.0] — stable API

yamleam's public API is now stable for the documented YAML 1.2 feature set. `YamlNode`, `YamlError`, `parse`, `parse_raw`, `parse_documents` and `parse_documents_raw` are covered by semantic versioning.

### Changed

- `parse_raw` and `parse` read exactly one document. Given a multi-document stream, they return a `ParseError` that points at the first line of the second document. `parse_documents_raw` and `parse_documents` read whole streams.

### Fixed

- Merge-key validation errors report the line and column of the offending `<<:` entry.

## 0.x — pre-1.0 development

The development releases that built up the 1.0 feature set:

- **0.5.1:** pure Gleam throughout. The anchor table became a plain `Dict` threaded through the parser, and the package now builds from Gleam sources alone.
- **0.5.0:** flow collections (`[…]`, `{…}`), anchors and aliases (`&name`, `*name`), and merge keys (`<<: *base`, `<<: [*a, *b]`) with in-place overrides.
- **0.3.0:** folded block scalars (`>`, `>-`, `>+`), multi-document streams (`---`, `...`) with `parse_documents` and `parse_documents_raw`, and exact content-indent detection for block scalars.
- **0.2.0:** literal block scalars (`|`, `|-`, `|+`) in every value position.
- **0.1.1:** duplicate mapping keys rejected as YAML 1.2 requires; out-of-range exponents such as `1e10000` resolve to strings.
- **0.1.0:** the first release, with block mappings and sequences, plain and quoted scalars, YAML 1.2 scalar resolution, and the `gleam/dynamic/decode` decoder layer.
