# yamleam

[![Package Version](https://img.shields.io/hexpm/v/yamleam)](https://hex.pm/packages/yamleam)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/yamleam/)

**A pure-Gleam YAML 1.2 parser.** Parse YAML into a typed tree, or decode it
straight into your own types with the same `gleam/dynamic/decode` decoders you
already use for JSON.

- **Pure Gleam.** No FFI, no NIFs, no C toolchain. `gleam add yamleam` is the
  whole setup.
- **Feels like `gleam_json`.** `yamleam.parse(source, decoder)` takes a standard
  decoder, so decoders written for JSON work on YAML unchanged.
- **Real-world YAML, and JSON too.** Block and flow collections, compact
  lists, literal and folded block scalars, anchors, aliases and merge keys,
  multi-document streams, and JSON documents.
- **YAML 1.2 semantics.** `no`, `off` and `0777` stay exactly as written: no
  Norway problem, no surprise octals.
- **Explicit errors.** Invalid input returns a typed error with its line and
  column, and features outside the supported set say so by name.
- **Stable API.** The 1.x public surface is covered by semantic versioning.

yamleam handles the YAML that runs services and pipelines: Kubernetes manifests,
`kubectl get -o yaml` output and multi-resource bundles, Helm values, GitHub
Actions workflows, GitLab CI pipelines that reuse settings through anchors and
merge keys, docker-compose files, application config, rulesets, and plain JSON.

## Installation

```sh
gleam add yamleam
```

yamleam works with Gleam 1.9 or later and `gleam_stdlib` 0.60 or later, on the
Erlang and JavaScript targets.

On JavaScript, numbers follow JavaScript's rules, as they do for `gleam_json`.
Integers beyond 2^53 lose precision, and an integral float such as `8080.0`
satisfies `decode.int`.

## Quick start

```gleam
import gleam/dynamic/decode
import yamleam

pub type Config {
  Config(name: String, port: Int, debug: Bool)
}

pub fn load_config() -> Result(Config, yamleam.YamlError) {
  let source =
    "
name: my-service
port: 8080
debug: true
"

  let decoder = {
    use name <- decode.field("name", decode.string)
    use port <- decode.field("port", decode.int)
    use debug <- decode.field("debug", decode.bool)
    decode.success(Config(name:, port:, debug:))
  }

  yamleam.parse(source, decoder)
}
```

## Guide

### The raw tree

`parse_raw` returns the typed `YamlNode` tree for direct pattern matching:

```gleam
import yamleam
import yamleam/node.{YamlList, YamlMap, YamlString}

pub fn main() {
  let assert Ok(tree) =
    yamleam.parse_raw(
      "
title: Example
items:
  - alpha
  - beta
",
    )

  let assert YamlMap([
    #("title", YamlString("Example")),
    #("items", YamlList([YamlString("alpha"), YamlString("beta")])),
  ]) = tree
}
```

Mappings keep their keys in source order.

### Compact lists

A list may sit at its key's own indent, the style kubectl and many CI tools
write:

```yaml
spec:
  containers:
  - name: web
    ports:
    - containerPort: 8080
```

This parses to the same tree as the indented form, so either style decodes the
same way.

### JSON is YAML

YAML 1.2 was designed to read JSON. yamleam parses JSON documents, whether
pretty-printed or compact, with the same decoders:

```json
{
  "name": "yamleam",
  "keywords": ["yaml", "gleam"],
  "author": {"city": "S\u00e3o Paulo"}
}
```

```gleam
import gleam/dynamic/decode
import yamleam

pub fn package_name(json: String) -> Result(String, yamleam.YamlError) {
  yamleam.parse(json, decode.at(["name"], decode.string))
}
```

Flow collections in YAML files may span lines the same way:

```yaml
args: [
  --port=8080,
  --verbose,
]
```

### Multi-document streams

`parse_documents` runs a decoder against every document in a `---`-separated
stream, and `parse_documents_raw` returns one `YamlNode` per document:

```gleam
import gleam/dynamic/decode
import yamleam

pub fn kinds() -> Result(List(String), yamleam.YamlError) {
  let source =
    "
---
kind: ConfigMap
name: app-config
---
kind: Service
name: app-svc
---
kind: Deployment
name: app-deploy
"

  yamleam.parse_documents(source, decode.at(["kind"], decode.string))
  // -> Ok(["ConfigMap", "Service", "Deployment"])
}
```

`parse` and `parse_raw` read exactly one document. Given a stream, they return a
`ParseError` that points at the second document, so no document is ever dropped
quietly.

### Anchors, aliases and merge keys

Define shared settings once and reuse them:

```yaml
defaults: &defaults
  retries: 3
  timeout: 60
  notify: ops@example.com

job_a:
  <<: *defaults
  command: build

job_b:
  <<: *defaults
  command: test
  timeout: 300       # overrides the merged value in place
```

`job_a` receives all three defaults plus its own `command`. `job_b` keeps
`retries` and `notify`, and its own `timeout` wins. A merge key also accepts a
list of aliases (`<<: [*base, *extra]`), and anchors are scoped to their
document.

### Block scalars

Embedded scripts and long text read naturally:

```yaml
script: |
  make build
  make test
summary: >
  Folded text joins
  into one line.
```

`script` is `"make build\nmake test\n"` and `summary` is
`"Folded text joins into one line.\n"`. Both styles accept the strip (`|-`,
`>-`) and keep (`|+`, `>+`) chomping indicators.

### Errors

Every failure is a `YamlError`:

```gleam
import gleam/int
import yamleam
import yamleam/error.{DecodeError, ParseError, Unsupported}

pub fn describe(source: String) -> String {
  case yamleam.parse_raw(source) {
    Ok(_) -> "ok"
    Error(ParseError(message:, line:, ..)) ->
      "line " <> int.to_string(line) <> ": " <> message
    Error(Unsupported(feature:, ..)) -> "not supported: " <> feature
    Error(DecodeError(..)) -> "decoder rejected the document"
  }
}
```

- `ParseError` covers input that isn't valid YAML, with a message, line and column.
- `Unsupported` names a YAML feature outside the supported set, with its position.
- `DecodeError` carries the decoder's own errors when the YAML parsed but its
  shape didn't match.

`error.to_string` formats any of them as one line:
`yaml parse error at line 2, column 1: duplicate mapping key 'a'`, or, for a
decoder's rejection, `yaml decode error at spec.port: expected Int, found String`.

## Feature reference

| Area | Supported |
|---|---|
| Structure | Block mappings (`key: value`), block sequences (`- item`), indented or compact, nesting to any depth, comments |
| Flow collections | `[1, 2, 3]` and `{a: 1, b: 2}`, on one line or across several, nested, inside block context |
| JSON | Pretty-printed and compact documents (`{"a":1}`), `\uXXXX` escapes and surrogate pairs |
| Plain scalars | Null, booleans, decimal integers, decimal floats with exponents, strings |
| Quoted strings | Single-quoted (`''` escape); double-quoted with every YAML 1.2 escape (`\n`, `\t`, `\"`, `\x41`, `\u00e9`, `\U0001F600`, …), folding across lines |
| Block scalars | Literal (`\|`, `\|-`, `\|+`) and folded (`>`, `>-`, `>+`), indentation auto-detected |
| Reuse | Anchors (`&name`), aliases (`*name`), merge keys (`<<: *base`, `<<: [*a, *b]`) |
| Streams | Multi-document streams with `---` and `...` markers |
| Validation | Duplicate mapping keys are rejected, as YAML 1.2 requires |
| Input | UTF-8 with or without a byte order mark; LF, CRLF or CR line endings |

### Scalar resolution

Plain (unquoted) scalars resolve by the YAML 1.2 rules:

| You write | You get |
|---|---|
| `null`, `Null`, `NULL`, `~`, or nothing | `YamlNull` |
| `true`, `True`, `TRUE`, `false`, `False`, `FALSE` | `YamlBool` |
| `42`, `-17`, `+3`, `0` | `YamlInt` |
| `3.14`, `-0.5`, `1e10`, `1.0E-3` | `YamlFloat` |
| `yes`, `no`, `on`, `off` | `YamlString` |
| `01234`, `0777` | `YamlString`, with the leading zeros kept |
| anything else | `YamlString` |

Quoted scalars are always strings, so `"123"` is `YamlString("123")`.

## Design

1. **Explicit by design.** yamleam never guesses: a document parses fully, or the
   error says what and where.
2. **Decoders you already know.** YAML decoding mirrors `gleam_json`, so one
   mental model covers both formats.
3. **Pure Gleam.** Even the anchor table is a plain `Dict` threaded through the
   parser. `gleam build` is all it takes.
4. **YAML 1.2 semantics.** Resolution follows the modern spec, which fixed YAML
   1.1's loose booleans and implicit octals.
5. **Clarity first.** A readable recursive-descent parser that is easy to
   review and extend, tested against the shapes real configs, manifests and
   rulesets take.

## Scope and limits

### Not yet supported

Each of these is handled explicitly today, with an error or, for the number
forms, a plain string. Most of them are on the [roadmap](ROADMAP.md).

| Feature | Today | Until it lands |
|---|---|---|
| Plain or single-quoted scalars spanning several lines | `ParseError` | Use `\|`, `>` or a double-quoted string |
| Tags (`!!str`, `!Custom`) | `Unsupported` | Planned |
| Explicit indentation indicators (`\|2`, `>+1`) | `ParseError` | Auto-detection covers the usual case |
| Complex keys (`? [a, b]`) | `ParseError` | Planned |
| Hex, octal and special floats (`0x1F`, `0o17`, `.inf`, `.nan`) | Resolve as strings | Planned |

### YAML 1.2 by design

YAML 1.1's `yes`/`no`/`on`/`off` booleans and `0777`-style octals are not
coming back. They stay strings, as YAML 1.2 specifies. Tabs are not allowed in
indentation, as the spec requires.

### Parsing untrusted input

yamleam parses eagerly and sets no limits of its own on document size or
nesting depth. Aliases expand into full copies of their anchored value, so a
small document can describe a very large tree. For YAML from outside your trust
boundary, cap the input size before parsing and run the parse under a timeout,
as you would for any parser of untrusted data.

## Roadmap

[ROADMAP.md](ROADMAP.md) has what's next: multi-line plain scalars first, then
core-schema tags and integers, explicit indentation indicators, and complex
keys.

## Contributing

Contributions are welcome. These help most:

- **Real-world YAML.** If a file from a production system doesn't parse, open an
  issue with a minimal sample, or a PR with a failing test.
- **Error messages.** Every error should say exactly what went wrong and where.
- **Documentation.** Examples, edge cases, and migration notes from `yamerl`.

For significant feature work, please open an issue first so we can agree on
scope and the release it fits.

## Development

```sh
gleam test       # Run the test suite
gleam build      # Compile the library
gleam docs build # Build the HTML docs
```

`.tool-versions` pins the toolchain we develop on (the latest Gleam and
Erlang/OTP), for mise or asdf.

### Compatibility

`gleam.toml` declares the oldest Gleam and `gleam_stdlib` versions yamleam
supports. Each release is tested on both that minimum and the latest toolchain,
on both targets (`gleam test --target javascript` runs the JavaScript suite).
Raising the minimum is reserved for a minor release and noted in the
changelog; a patch release never raises it.

## License

Apache-2.0.

## Acknowledgements

Thanks to the maintainers of Gleam, `yamerl`, `yaml-rust`, and `ocaml-yaml`.
