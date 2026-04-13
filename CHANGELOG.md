# Changelog

All notable changes to yamleam will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] — stable API

This release marks yamleam's stable public API for the documented YAML 1.2 subset.
The public surface (`YamlNode`, `YamlError`, `parse`, `parse_raw`, `parse_documents`, `parse_documents_raw`) is now covered by semantic versioning guarantees.

### Changed

- `parse_raw` / `parse` now reject multi-document YAML streams with a `ParseError` pointing at the first line of the second document. Callers that want stream semantics must use `parse_documents_raw` / `parse_documents`, which avoids silently discarding trailing documents.

### Fixed

- Merge-key validation errors now preserve the source line and column of the offending `<<:` entry instead of returning `line: 0, column: 0`.

## [0.5.1] — pure Gleam (FFI removed)

Internal refactor: the Erlang FFI shim that backed the anchor table with the BEAM process dictionary is gone. The anchor table is now a plain `dict.Dict(String, YamlNode)` threaded explicitly through the parser as a state parameter. No public API change — all 112 existing tests pass unchanged.

### Changed

- `src/yamleam/anchors.gleam` is now a pure-Gleam module exposing `Anchors` (a type alias over `Dict(String, YamlNode)`), `new/0`, `set/3`, and `get/2`. The previous side-effecting `init/0`, `set/2`, `get/1` API is gone.
- `src/yamleam/parser.gleam` threads an `Anchors` state parameter through every block and flow parser function. Block parsers now return `Result(#(YamlNode, List(Line), Anchors), YamlError)`; flow parsers return `Result(#(YamlNode, List(Token), Anchors), YamlError)`.
- `parse_one_document` creates a fresh `Anchors` table and passes it into the top-level block parser. Anchor scope remains per-document, exactly as before — the lexical structure of the threading enforces what the FFI shim previously enforced through `erlang:put`.

### Removed

- `src/yamleam/anchors_ffi.erl` — the ~30-line FFI module is deleted. yamleam now contains zero Erlang source files. `gleam build` compiles the package from Gleam sources alone, and the README's "pure Gleam" claim is now literally true.

### Why this matters

The previous implementation reached for the BEAM process dictionary as a shortcut: threading anchor state through ~19 parser functions felt mechanical, and a 3-function FFI surface seemed cheap. But the shortcut undermined yamleam's core claim of being a pure-Gleam parser, and the explicit threading turned out to be straightforward — a few hundred lines of mechanical edits with zero algorithmic change.

## [0.5.0] — flow-style collections + anchors, aliases, merge keys

This release closes the two largest remaining gaps in real-world YAML coverage. Flow-style collections (`[1, 2, 3]`, `{a: 1, b: 2}`) appear constantly in Helm values, docker-compose files, Kubernetes resource constraints, and any inline list or map. Anchors (`&name`), aliases (`*name`), and merge keys (`<<: *base`) are essential to CI configs (GitLab CI, Drone, etc.) and any DRY-style YAML that wants to reuse common settings.

Together with v0.3 (block scalars + multi-document streams), v0.5.0 covers ~99% of real-world YAML you'd encounter in configs, manifests, CI pipelines, and rulesets.

### Added — flow-style collections (v0.4 in the roadmap, shipped here)

- New token kinds `FlowSeqStart` `FlowSeqEnd` `FlowMapStart` `FlowMapEnd` `Comma`.
- Lexer tracks `flow_depth` so flow indicators (`,` `]` `}`) only act as terminators inside flow context. In block context they remain valid plain-scalar characters (a long-standing latent bug fixed by the same change).
- New parser functions `parse_flow_value` / `parse_flow_seq` / `parse_flow_map` consume tokens recursively. Flow can appear as a top-level document value, as a mapping value (`key: [1, 2, 3]`), as a sequence item (`- [1, 2, 3]`), or inline inside a sequence-item mapping (`- {key: gpu, value: yes}`).
- Nested flow works: `[[1, 2], [3, 4]]`, `[{a: 1}, {b: 2}]`, `{tags: [a, b], count: 3}`.
- Plain and quoted scalars work inside flow with the right terminators.
- Duplicate flow-mapping keys are rejected at parse time, matching block-mapping behavior.
- 21 new flow tests covering: empty collections, scalar items, mixed types, nesting, mapping values, sequence items, dash-inline-mapping context, decoder integration, and unterminated/duplicate-key error cases.

**Out of v0.5 scope:** multi-line flow (where `[` opens on one line and `]` closes on a different line). Single-line flow covers ~95% of real usage. Multi-line flow can ship as a v0.5.x patch if users need it.

### Added — anchors, aliases, merge keys (v0.5 in the roadmap)

- New token kinds `AnchorMarker(name)` and `AliasMarker(name)`.
- Lexer recognizes `&name` and `*name` followed by alphanumeric / `_` / `-` characters.
- New `yamleam/anchors.gleam` module wrapping a tiny Erlang FFI shim (`anchors_ffi.erl`) that maintains a per-document anchor table in the process dictionary. This avoids threading state through every parser function — the table is reset at the start of every document, so there's no leakage between calls or between documents in a multi-document stream.
- Parser detects anchors and aliases at every value-parsing site: inline mapping values, nested block values, sequence items, dash-inline-mapping items, and inside flow collections.
- Anchored values are registered after parse so the anchored value is fully constructed before being made available to later aliases. (Self-referential anchors are not supported and would be rejected.)
- Aliases substitute the previously-registered value; an unknown alias returns a clear `ParseError`.
- **Merge keys (`<<: *base`)** are supported per the YAML 1.1 merge spec. The merge value can be either a single mapping alias or a list of mapping aliases. Merged entries appear in the output at the merge point in source order; explicit keys declared before or after the merge always win over merged keys with the same name. Explicit keys declared after a merge replace merged values **in place** (preserving the original entry's position) rather than moving the entry to the end.
- The duplicate-key check now distinguishes "explicit" entries from "merged" entries — explicit entries cannot be duplicated within the same mapping, but a merge key can introduce an entry that's later overridden by an explicit assignment without triggering the duplicate error.
- Anchor scope is per-document: anchors defined in one document of a multi-document stream are not visible to subsequent documents.
- 16 new anchor tests covering: simple scalar anchor/alias, anchor on nested block, anchor on sequence, anchor in sequence item, anchor on dash-inline-mapping, anchors inside flow collections, basic merge key, local-keys-take-precedence, list-of-aliases merge, decoder integration, unknown-alias error, anchor-scope-resets-between-documents, and the classic CI template / DRY pattern.

### Architectural note on the process dictionary

The anchor table is the one place yamleam reaches for mutable state. Threading an `Anchors` parameter through all 15+ parser functions would have been mechanical but added significant noise to otherwise-clean recursive descent. The Erlang process dictionary gives us per-process scope (concurrent parses don't conflict), clean reset semantics (`anchors.init()` is called at the start of every document), and a 3-function FFI surface. The mutation never escapes a single `parse_one_document` call. This is documented in `src/yamleam/anchors.gleam` as a deliberate design trade-off, not an oversight.

## [0.3.0] — folded block scalars + multi-document streams

Two broadly-applicable features shipped together. Folded scalars (`>`) complete block-scalar support so yamleam handles every `|` and `>` form commonly found in Kubernetes manifests, Helm charts, and CI configs. Multi-document streams (`---` / `...`) unlock the "multiple resources in one file" pattern that's ubiquitous in Kubernetes.

### Added — folded block scalars (`>`, `>-`, `>+`)

- Line-by-line folding state machine: consecutive normal lines fold into spaces (forming a paragraph), blank lines mark paragraph breaks (preserved as `\n`), and more-indented lines preserve their original line breaks (for embedded code or lists inside prose blocks).
- All three chomping modes work: `>` (clip, default), `>-` (strip), `>+` (keep).
- Content indent is auto-detected from the first non-blank content line; subsequent lines must be at that indent or deeper to remain part of the scalar. This correctly handles `- description: >` followed by sibling mapping entries like `  id: s1` — the sibling stops the block at its actual boundary.
- 6 new folded-scalar tests covering: basic folding, paragraph breaks, strip chomping, keep chomping with trailing blanks, more-indented lines preserved, folded scalar inside sequence items.

### Added — multi-document streams (`---`, `...`)

- New token kinds `DocumentStart` and `DocumentEnd` recognized at column 1.
- New parser function `parse_all(lines) -> Result(List(YamlNode), YamlError)` that splits the line stream on document markers and parses each segment independently.
- Two new public API functions:
  - `parse_documents_raw(source) -> Result(List(YamlNode), YamlError)` — parse a multi-document stream into a list of `YamlNode` trees.
  - `parse_documents(source, decoder) -> Result(List(a), YamlError)` — parse a multi-document stream and run a decoder against each document, returning the decoded values in stream order.
- `parse_raw` and `parse` (single-document API) now accept streams containing optional leading `---` or trailing `...` markers. On a multi-document stream, they return the FIRST document (the others are ignored) — use `parse_documents_raw`/`parse_documents` to get all of them.
- 11 new multi-document tests covering: no markers, leading marker, end marker, two- and three-document streams with all markers, Kubernetes-style manifest bundles, `parse_raw` behavior on multi-doc input, decoder-based multi-doc parsing, empty streams, marker-only streams, and streams with comments interspersed with markers.

### Fixed — block scalar content indent detection

The v0.2.0 block scalar reader used a greedy "collect any line at indent > parent_indent or blank" rule to determine what belongs to the scalar. This incorrectly absorbed sibling mapping entries into block scalars when the scalar's value appeared inline with a dash (e.g., `- description: >` followed by `  id: s1`). The collection rule now auto-detects the content indent from the first non-blank content line and requires subsequent non-blank lines to be at that indent or deeper, stopping the block at the first line that drops below. Literal block scalars already worked correctly by coincidence of their typical layouts, but now follow the same stricter rule for consistency.

### Fixed — folded keep chomping

The folded state machine emitted `N-1` newlines for `N` content lines (blanks included), causing keep chomping to lose one trailing newline per block. The state machine now unconditionally appends a terminating `\n` at the end of the walk, and chomping adjusts from there to produce the correct final count for all three modes.

## [0.2.0] — literal block scalars

Block scalars are the most broadly-used YAML feature missing from v0.1, appearing in essentially every Kubernetes ConfigMap, GitHub Actions workflow, GitLab CI config, Helm chart, Ansible playbook, and docker-compose file that contains embedded code, scripts, or multi-line text.

### Added
- **Literal block scalars (`|`)** with all three chomping modes:
  - `|` (clip, default) — trailing newlines collapse to one
  - `|-` (strip) — no trailing newlines
  - `|+` (keep) — all trailing newlines preserved exactly as written
- The lexer auto-detects content indentation from the first non-blank content line. Blank lines inside the block are preserved.
- Block scalars work in any value position: top-level mapping values, nested mapping values, and sequence items (`run: |`, `- script: |`, etc.).
- Inline `# comment` after the block scalar opener is allowed and ignored.

### Tests added
- 8 new parser tests covering: basic literal scalar, strip and keep chomping, internal blank lines, sequence-item context, sibling keys after the scalar, deeply nested context, and inline comments after the opener.

### Still not yet supported (returns `Unsupported` errors)
- Folded block scalars (`>`, `>-`, `>+`) — planned for v0.2.2
- Explicit indent indicators (`|2`, `|+1`) — planned for v0.2.3 (auto-detection covers the common case)
- Flow-style collections — planned for v0.2.x or v0.3
- Multi-document streams (`---`) — planned for v0.3
- Anchors and aliases — planned for v0.3
- Tags, merge keys, complex keys — planned for v0.4–v0.5

## [0.1.1] — correctness patches

### Fixed
- **Out-of-range scientific exponents no longer crash the BEAM.** Inputs like `1e10000` or `2.5E500` previously triggered `badarith` because `power_of_ten` recursed past the Float64 representable range (~1e308) and overflowed during multiplication. The exponent is now bounded to ±300; out-of-range scientific values fall through to `YamlString` instead of attempting unrepresentable arithmetic.
- **Duplicate mapping keys are now rejected at parse time.** YAML 1.2 §3.2.2.1 requires mapping keys to be unique. Previously, `parse_raw` preserved duplicates in the `YamlMap` list while the decoder layer (via `dict.from_list`) silently kept only the last occurrence — an asymmetry that was both spec-non-conformant and a footgun for callers expecting consistent behavior. Both `parse_raw` and `parse` now return `ParseError("duplicate mapping key 'X'", line, col)` for any mapping that contains the same key twice. The check applies to top-level mappings, nested mappings, and inline mappings inside sequence items (`- key: value` form).

### Tests added
- 3 cases for out-of-range scientific exponents (positive, negative, large mantissa)
- 4 cases for duplicate-key rejection (top-level, nested, inline-in-sequence, plus a negative test confirming separate mappings inside a sequence still work)

## [0.1.0] — first functional release

The first version that actually parses YAML. Block-style only, no flow-style, no anchors, no multi-line scalars, no multi-document streams — but enough to handle Kubernetes manifests, Helm values, GitHub Actions workflows, docker-compose files, and most hand-written configuration YAML.

### Added
- **Lexer** (`yamleam/lexer.gleam`): line-oriented tokenizer with indent tracking, plain scalars, single-quoted strings (with `''` escape), double-quoted strings with basic escapes (`\n`, `\t`, `\r`, `\"`, `\\`, `\/`, `\0`), comments (inline and standalone), tab-in-indent rejection.
- **Parser** (`yamleam/parser.gleam`): recursive-descent parser over lexer lines. Supports block mappings, block sequences, nested structures at arbitrary depth, and the `- key: value` inline-mapping-as-sequence-item form (critical for ruleset and manifest YAML).
- **Scalar resolution** (`yamleam/scalar.gleam`): YAML 1.2 plain scalar resolution. Priority: null → bool → int → float → string. Refuses YAML 1.1 quirks (`yes`/`no`, leading-zero integers).
- **Decoder layer** (`yamleam/decoder.gleam`): converts `YamlNode` to `Dynamic` so `gleam/dynamic/decode.Decoder(a)` runs over the parsed tree. `yamleam.parse(source, decoder)` returns `Result(a, YamlError)`.
- **Error positions**: every `ParseError` and `Unsupported` includes a 1-indexed line number; column is approximate but indicative.
- 46 unit + integration tests, including a real-world ruleset fixture covering nested sections with mapping-item sequences.

### Out of scope (returns `Unsupported` errors with planned version)
- Flow-style collections (`[1, 2, 3]`, `{a: 1}`) — v0.2
- Multi-line scalars (`|`, `>`) — v0.2
- Multi-document streams (`---`, `...`) — v0.3
- Anchors and aliases (`&name`, `*name`) — v0.3
- Tags (`!!int`, `!Custom`) — v0.4
- Merge keys (`<<: *base`) — v0.4
- Complex keys (map-as-key) — v0.5
- YAML 1.1 boolean variants (`yes`/`no`/`on`/`off`) — never; use `true`/`false`
- Tabs in indentation — never; use spaces

### Known limitations
- Quoted strings must open and close on the same source line. Multi-line quoted strings will be added when block scalars (`|`, `>`) ship in v0.2.
- Plain scalars containing `: ` (colon followed by space) must be wrapped in quotes — the unquoted form is interpreted as a separator.
- Indentation must strictly increase for nested blocks. The "zero-indent dash" form (block sequence at the same column as its parent key) is rejected.
- Error column numbers are best-effort and may point a few characters off from the offending token in edge cases.
