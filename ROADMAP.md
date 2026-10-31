# yamleam roadmap

Where yamleam is going, release by release. The [README](README.md) is the
reference for what ships today; this file covers what comes next and why.

## Principles

Every release keeps these commitments:

1. **Correct or explicit.** A document parses to the right tree, or yamleam
   returns an error that names the problem. Wrong output is always treated as a
   defect, whatever the spec coverage.
2. **The README is the contract.** Its feature reference tells you, before you
   try, whether your YAML will parse.
3. **Tests lead.** Each feature starts as a failing test against realistic
   input, and the parser grows to pass it.
4. **Errors are first-class output.** An error should give the line, the
   column and what was expected. We aim for the error quality of Elm and Rust.
5. **Pure Gleam.** Every line of yamleam is Gleam. When a primitive is missing,
   we change the approach rather than add an FFI shim.
6. **Clarity first.** The implementation stays easy to read and contribute to.
   Performance work follows real workloads that need it.

## 1.0: stable API

The public API is stable under semantic versioning: `parse`, `parse_raw`,
`parse_documents`, `parse_documents_raw`, `YamlNode`, `YamlError`. It covers the
YAML that services and pipelines run on:
- block and single-line flow collections;
- plain, quoted, literal and folded scalars;
- anchors, aliases and merge keys;
- multi-document streams;
- duplicate-key rejection;
- YAML 1.2 scalar resolution.

## 1.1: compact sequences and complete escapes (shipped)

- **Compact sequences:** a block sequence at its key's own indent (`steps:`
  followed by `- run: make`), the style kubectl, GitHub Actions, Ansible and
  OpenAPI tooling emit.
- **Complete double-quoted escapes:** the full YAML 1.2 set, including `\u`,
  `\x`, `\U`, `\b`, `\f` and escaped line breaks. Unknown escapes become
  explicit errors.

## 1.2: multi-line flow and JSON (shipped)

- **Flow collections across lines:** `[` and `{` collections that open on one
  line and close on another.
- **JSON documents:** pretty-printed and compact JSON parse as YAML, including
  `"key":value` with no space after the colon.

## 1.3: JavaScript target (shipped)

- **JavaScript:** the full test suite runs on both targets, with no npm
  dependency.

## 1.4: wrapped values (shipped)

- **Multi-line plain and single-quoted scalars:** hand-written YAML, such as
  OpenAPI descriptions, wraps long values across lines. They fold as YAML 1.2
  specifies, and a key that would span lines is an explicit error.

## Later in 1.x

- **Core-schema tags (next):** `!!str`, `!!int`, `!!float`, `!!bool`, `!!null`,
  `!!seq`, `!!map`.
- **Core-schema integers:** hex (`0x1F`) and octal (`0o17`).
- **Explicit indentation indicators:** `|2`, `>+1`.
- **Complex keys:** `? [a, b]`.

Each of these is additive and fits inside the stable 1.x API.

## 2.0 candidates

These would change the public types, so they wait for a major version, guided
by what users ask for:

- **Custom tags kept in the tree** (`!Ref`, `!Sub`, `!include`), which needs a
  new `YamlNode` variant.
- **Serialization:** emitting YAML from `YamlNode` and from typed values.
- **Streaming:** parsing large files without building the whole tree.
- **Performance:** benchmarks against `yamerl` and `yaml-rust`, then the hot
  paths.
- **A tighter module surface:** marking the lexer, parser and token modules as
  internal.

## YAML 1.2 by design

YAML 1.1's loose booleans (`yes`, `no`, `on`, `off`) and implicit octals
(`0777`) are permanently out of scope. YAML 1.2 removed them for good reasons,
and yamleam follows 1.2.

## Proposing changes

Open an issue that describes the change, the YAML it unlocks, and the release
you think it fits. Roadmap changes get a careful review, because they decide
where the project goes.
