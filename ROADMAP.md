# yamleam ROADMAP

This document is the project's long-term plan. It covers the v0.1 implementation in detail and sketches v0.2 through v1.0 at progressively coarser granularity. The plan is authoritative for what we're building; the [README](README.md) is authoritative for what ships to users.

This file is expected to evolve. Check the git history for the record of how our thinking changed.

---

## Guiding principles

Before detailed plans, the invariants we commit to at every version:

1. **Never silently produce wrong output.** Every feature we don't support must return `YamlError.Unsupported("...")` with a clear description of what was encountered. Silent misparsing is the one failure mode we treat as a defect, always, regardless of spec coverage.
2. **The README coverage matrix is the source of truth.** If a feature isn't listed as supported, it isn't supported. If a user opens the README and reads the matrix, they can predict whether their YAML will parse before they try it.
3. **Tests are authored before parser code.** Each feature begins as a failing test against a realistic input, then the parser grows to pass it. No "write parser, hope tests exist."
4. **Error messages are treated as first-class output.** An error that doesn't tell you the line, the column, and what was expected is a bug. We aim for error quality on par with Elm and Rust.
5. **No FFI.** Every line of yamleam is Gleam. If we need a primitive Gleam doesn't expose, we prefer changing the approach over adding an Erlang shim.
6. **Performance is a v2 concern.** v0.x and v1.x optimize for correctness, clarity, and ease of contribution. Measurable performance work starts at v2 or later, and only if a real user hits a bottleneck.

---

## v0.1 — Block-style subset

**Goal:** the smallest implementation that parses realistic configuration YAML. This covers roughly 95% of the YAML files people actually write, including Kubernetes manifests without anchors, GitHub Actions workflows, Helm values files, docker-compose files, ruleset definitions, and ordinary config files.

### Supported surface (commit to shipping this)

- **Whitespace + comments** — line comments (`# ...`), trailing comments, comment-only lines
- **Block-style mappings** — `key: value` with arbitrary nesting via indentation
- **Block-style sequences** — `- item` with arbitrary nesting, nested within mappings
- **Plain (unquoted) scalars** — resolved to null / bool / int / float / string via the resolution rules below
- **Single-quoted strings** — `'...'`, with `''` as the escape for embedded quotes
- **Double-quoted strings** — `"..."`, with escapes: `\n`, `\t`, `\r`, `\"`, `\\`, `\/`, `\0`, `\b`, `\f`
- **Explicit null** — `null`, `Null`, `NULL`, `~`, or an empty value
- **Booleans** — `true`, `True`, `TRUE`, `false`, `False`, `FALSE` (YAML 1.2 only, no `yes`/`no`)
- **Integers** — decimal (`42`, `-17`, `+3`)
- **Floats** — decimal with optional exponent (`3.14`, `1e10`, `-0.5`, `1.0E-3`)
- **Strings** — fallback for any plain scalar that doesn't resolve to another type

### Plain scalar resolution priority

When a plain (unquoted) scalar is encountered, try each in order:

1. `null`, `~`, `Null`, `NULL`, empty → `YamlNull`
2. `true`, `True`, `TRUE` → `YamlBool(True)`
3. `false`, `False`, `FALSE` → `YamlBool(False)`
4. Decimal integer (with optional sign) → `YamlInt(...)`
5. Decimal float (with optional sign, optional exponent) → `YamlFloat(...)`
6. Otherwise → `YamlString(...)` (the verbatim text)

Quoted scalars are always strings regardless of their content. `"123"` is `YamlString("123")`, not `YamlInt(123)`.

### Execution phases

Implementation is split into 9 phases, each ending in `gleam build && gleam test` passing with zero warnings.

#### Phase 1 — Project scaffold
- `gleam new yamleam` (done)
- `gleam.toml` with metadata (done)
- `README.md` with status matrix (done)
- `ROADMAP.md` — this file (done)
- `CHANGELOG.md` with `[Unreleased]` section
- `.tool-versions` for gleam + rebar
- `LICENSE` (Apache-2.0)
- Empty `src/yamleam.gleam` that compiles

**Done when:** `gleam build` compiles cleanly.

#### Phase 2 — Types and public API shape

Build the type surface before any parsing logic. The types are the contract; everything else serves them.

Files:
- `src/yamleam.gleam` — public API: `YamlNode`, `YamlError`, `parse/2`, `parse_raw/1`
- `src/yamleam/token.gleam` — `Token`, `Position`, `Tokens`
- `src/yamleam/error.gleam` — error types and formatters

Public types:

```gleam
pub type YamlNode {
  YamlNull
  YamlBool(Bool)
  YamlInt(Int)
  YamlFloat(Float)
  YamlString(String)
  YamlList(List(YamlNode))
  YamlMap(List(#(String, YamlNode)))
}

pub type YamlError {
  /// The source is not valid YAML (or not valid in the subset we support).
  ParseError(message: String, line: Int, column: Int)
  /// The source uses a YAML feature we don't yet implement.
  Unsupported(feature: String, line: Int, column: Int)
  /// The source parsed, but the decoder rejected it.
  DecodeError(errors: List(dynamic_decode.DecodeError))
}

pub fn parse_raw(source: String) -> Result(YamlNode, YamlError)
pub fn parse(source: String, decoder: Decoder(a)) -> Result(a, YamlError)
```


#### Phase 3 — Lexer

The hardest single piece of v0.1. YAML's lexer is indentation-sensitive, which means it must track the current column and emit synthetic `Indent` / `Dedent` tokens when the indent level changes.

Files:
- `src/yamleam/lexer.gleam` — main lexer
- `src/yamleam/lexer/source.gleam` — character-stream helpers (peek, advance, position tracking)
- `test/yamleam/lexer_test.gleam` — token sequence assertions

Tokens to emit:
- `Indent(col: Int)` — opening a new indent level
- `Dedent(col: Int)` — closing an indent level
- `Newline` — end of a logical line
- `Colon` — `:`
- `Dash` — `-` at the start of a sequence item
- `PlainScalar(text: String)` — an unquoted scalar
- `SingleQuoted(text: String)` — raw content with `''` already decoded
- `DoubleQuoted(text: String)` — raw content with escapes already decoded
- `Comment(text: String)` — we collect but don't emit to the parser by default
- `Eof`

Lexer test strategy: for each input, assert the exact token sequence. Start with trivial inputs (a single scalar, a single `key: value`) and build up incrementally.

**Done when:** `lexer_test.gleam` has ~30 tests covering:
- Single line mappings
- Nested mappings
- Sequences
- Mixed mapping + sequence nesting
- All three scalar flavors
- Comments (inline, trailing, standalone)
- Edge cases: empty file, leading whitespace, trailing newlines

#### Phase 4 — Parser

Consumes `Token` list and builds `YamlNode`. Recursive descent, dispatching on the first token of each node.

Files:
- `src/yamleam/parser.gleam`
- `test/yamleam/parser_test.gleam`

Parser tests begin at the token level (pre-lexed inputs) to isolate parser bugs from lexer bugs. Once both layers are green, integration tests run full source strings through `parse_raw`.

**Done when:** `parser_test.gleam` has ~30 tests covering:
- Flat maps
- Flat sequences
- Nested maps
- Nested sequences
- Sequences inside maps
- Maps inside sequences
- Deep nesting (4+ levels)
- All scalar types appearing as values
- Empty collections (`:` with no value, `-` with no value)

#### Phase 5 — Scalar resolution

Convert `PlainScalar(text)` tokens into typed `YamlNode` variants. This is small but error-prone.

Files:
- `src/yamleam/scalar.gleam`
- `test/yamleam/scalar_test.gleam`

Resolution happens after the parser has assembled a node; `scalar.resolve("42")` returns `YamlInt(42)`, `scalar.resolve("3.14")` returns `YamlFloat(3.14)`, `scalar.resolve("true")` returns `YamlBool(True)`, etc.

Tests cover the entire resolution priority table, boundary cases (empty string → null), and ambiguous inputs (e.g., `"01"` → string, not int, because leading-zero integers are ambiguous).

**Done when:** every row in the resolution priority table has a passing test.

#### Phase 6 — Decoder layer

Wrap the `gleam/dynamic/decode` decoder machinery over `YamlNode`. This is the user-facing convenience layer; without it people have to pattern-match `YamlNode` manually.

The implementation converts our `YamlNode` to a `Dynamic` that the stdlib decoders understand, then runs the decoder. Because Gleam's decoder API is built on `Dynamic`, this amounts to emitting an Erlang term that matches the shapes the decoders expect (maps for objects, lists for arrays, primitives for scalars).

Files:
- `src/yamleam.gleam` — add `parse(source, decoder)` on top of `parse_raw`
- `test/yamleam/decoder_test.gleam`

**Done when:** a test parses a real config into a Gleam record via a decoder and the resulting record matches the expected value.

#### Phase 7 — Real-world fixture tests

Collect ~10 real YAML files from common sources and verify yamleam parses them. This is the most valuable test category because it catches bugs that synthetic tests miss.

Fixtures to collect:
1. `test/fixtures/kubernetes_deployment.yaml` — a minimal k8s Deployment manifest
2. `test/fixtures/github_actions.yaml` — a simple CI workflow
3. `test/fixtures/helm_values.yaml` — a Helm values.yaml
4. `test/fixtures/docker_compose.yaml` — a docker-compose.yml
5. `test/fixtures/ansible_playbook.yaml` — a simple Ansible playbook
6. `test/fixtures/config_simple.yaml` — a hand-written config with mixed types
7. `test/fixtures/nested_deep.yaml` — deeply nested map-in-list-in-map
8. `test/fixtures/comments_heavy.yaml` — lots of comments everywhere
9. `test/fixtures/quoted_strings.yaml` — single, double, and plain strings mixed
10. `test/fixtures/ruleset_example.yaml` — a realistic business-rules configuration

Each fixture gets a test that:
1. Parses it with `yamleam.parse_raw`
2. Asserts specific keys / values exist in the resulting tree
3. Does NOT assert full tree equality (too brittle — we only care that the important bits are correct)

Fixtures that use features we don't support (anchors, multi-doc) get a separate assertion: "parses with `Unsupported("anchors...")` error." This ensures our error reporting works and documents what's expected to fail.

**Done when:** every fixture in `test/fixtures/` has a corresponding test that passes (either parses successfully with expected values, or returns the expected `Unsupported` error).

#### Phase 8 — Error message polish

Make error messages as helpful as we can without re-architecting. Tests go in `test/yamleam/error_test.gleam`. Each test asserts:
- A known-bad input
- The expected `ParseError` or `Unsupported` with specific line/column and a message that says what was expected

Example expected messages:
- `ParseError("expected ':' after key, got '-'", line: 3, column: 5)`
- `ParseError("inconsistent indentation: expected 2 spaces, got 4", line: 7, column: 1)`
- `Unsupported("flow-style sequences '[...]' — planned for v0.2", line: 2, column: 10)`

**Done when:** every error path exercised by tests has a message a human can immediately act on.

#### Phase 9 — Documentation pass

- Flesh out `README.md` with any newly discovered quirks
- Add inline `///` doc comments on every public function and type
- Verify `gleam docs build` succeeds and the generated HTML reads cleanly
- Update `CHANGELOG.md` with the v0.1.0 entry


### v0.1 success criteria

- All unit tests pass (lexer, parser, scalar, decoder, error)
- All 10 real-world fixture tests pass
- README coverage matrix matches what the code actually does
- Zero compile warnings
- `gleam docs build` succeeds
- A consumer can write `let decoder = ...; yamleam.parse(source, decoder)` and get a typed value back for any of the 10 fixtures
- Every feature in the "not supported" list returns `Unsupported(feature, line, col)` when encountered


---

## v0.2 — Flow style + multi-line scalars

**Goal:** cover the next most-used YAML features. Flow style (`[1, 2, 3]`, `{a: 1}`) is common in small inline lists. Multi-line scalars (`|`, `>`) are common in string-heavy YAML like GitHub Actions `run:` blocks.

### Scope

- Flow-style sequences: `[item1, item2, item3]`, with nesting
- Flow-style mappings: `{key: value, key2: value2}`, with nesting
- Mixed flow-block (flow style inside a block context and vice versa)
- Literal block scalars (`|`, `|-`, `|+`, `|1`, `|2`, ...)
- Folded block scalars (`>`, `>-`, `>+`)


---

## v0.3 — Multi-document + anchors + line folding

**Goal:** cover the rest of "common YAML".

### Scope

- Multi-document streams: `---` and `...` separators, returning a list of documents
- Anchors: `&name` defines an anchor, `*name` references it
- Line folding in quoted strings (backslash continuation)
- Aliasing semantics: shared subtrees (the spec allows shared references; we copy)

### Open design question

Anchor resolution: do we resolve anchors at parse time (producing a fully-expanded tree) or preserve them structurally? **Decision for v0.3:** resolve at parse time. Users almost never need to distinguish an aliased reference from a copy; resolved trees are simpler to decode.

---

## v0.4 — Merge keys + tags

**Goal:** cover the rest of "structured YAML".

### Scope

- Merge keys: `<<: *base` merges the referenced map into the current map
- Core tags: `!!str`, `!!int`, `!!float`, `!!bool`, `!!null`, `!!seq`, `!!map`
- Custom tags: `!foo` — preserved structurally but not interpreted by yamleam


---

## v0.5 — Complex keys + remaining edge cases

**Goal:** cover the long tail.

### Scope

- Complex keys: a map or sequence appearing as a mapping key (via the `?` explicit-key marker)
- Handling for all the scalar edge cases we skipped in v0.1 (hex, octal, infinity, NaN)
- UTF-8 BOM stripping
- Mixed line endings (CRLF, CR-only)

---

## v0.6 — v0.9 — Feedback and hardening

Bug fixes, incremental features, error-message improvements, and spec-compliance hardening based on issues filed by users.

---

## v1.0 — Stable API

**Goal:** commit to semver. The public API shape freezes. Users can rely on yamleam for production workloads without fear of breaking changes.

### What changes at v1.0

- `version = "1.0.0"` in `gleam.toml`
- README prominently states "stable API"
- Breaking changes become minor or major version bumps governed by semver
- The coverage matrix freezes for features we explicitly committed to support
- Features we decided not to support (YAML 1.1 quirks) are listed as "will not be added" in perpetuity

### What does NOT gate v1.0

Spec completeness is NOT a v1.0 requirement. yamleam can reach v1.0 with a documented subset that's smaller than YAML 1.2. The commitment we make at v1.0 is "the API is stable," not "we support every YAML feature."

---

## v2.0+ — Speculative

Beyond v1.0 is speculative. Candidate directions:

- **Performance pass** — benchmark against yamerl and yaml-rust, optimize hotspots
- **Serialization** — emit YAML from `YamlNode` and from typed values
- **Streaming parser** — parse large files without loading the whole tree into memory
- **YAML schema validation** — cross-check against a schema definition
- **LSP support** — error squigglies for YAML files in editors via a Gleam LSP

None of these are committed. They depend on what users actually ask for.

---

## How to contribute to this roadmap

If you have thoughts on priority, scope, or direction:

1. Open an issue describing the change you'd like to see
2. Reference this file's current state
3. Propose the diff you'd want to make

Roadmap changes are reviewed more carefully than code changes — we want to be sure the project is going somewhere useful.
