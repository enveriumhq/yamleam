# yamleam

A **pure-Gleam YAML parser**.

The library aims to be a functionally correct implementation of the spec for the sections widely used in, broadly speaking, "commercial, service and operations" fields. For perspective, we aimed version **0.1** to cover 95%+ of the YAML files people actually write, including Kubernetes manifests without anchors, GitHub Actions workflows, Helm values files, docker-compose files, ruleset definitions, and ordinary config files.

We were surprised and impressed with the deeper layers of information architecture theory addressed by the spec. We believe that depth maps to specialized domains, but urge you to review the current coverage for your case. 

Known unsupported features are intended to fail explicitly instead of producing wrong output. 

---

## Why yamleam?

yamleam exists to provide a pure-Gleam implementation that:

- **Ships as a regular hex package** with no FFI or C dependencies
- **Returns typed `YamlNode` values** that you decode with `gleam/dynamic/decode`-style decoders
- **Mirrors the `gleam_json` API** so existing Gleam users can adopt it with muscle memory
- **Prioritizes correctness over feature completeness** — a small supported subset done right, not a large subset done approximately
- **Fails loudly and helpfully** when you hit unsupported features, never silently

## Coverage matrix

yamleam ships with partial coverage of YAML 1.2, and is not planned to reach parity with the full substantial specification - as mentioned earlier, we do believe the covered surface will benefit a vast swath of the format's users. This matrix is the source of truth for what is and isn't supported in the current version.

### Supported (v1.0.0)

| Feature | Status |
|---|---|
| Comments (`# ...`) | ✓  |
| Block-style mappings (`key: value`) | ✓ |
| Block-style sequences (`- item`) | ✓ |
| Nested structures (arbitrary depth via indentation) | ✓ |
| Plain scalars (unquoted) | ✓ |
| Single-quoted strings | ✓ |
| Double-quoted strings with basic escapes (`\n`, `\t`, `\"`, `\\`, `\/`, `\r`) | ✓ |
| Literal block scalars (`\|`, `\|-`, `\|+`) | ✓ |
| Folded block scalars (`>`, `>-`, `>+`) | ✓ |
| Multi-document streams (`---`, `...`) | ✓ |
| Flow-style sequences (`[1, 2, 3]`) | ✓  |
| Flow-style mappings (`{a: 1, b: 2}`) | ✓  |
| Anchors and aliases (`&name`, `*name`) | ✓  |
| Merge keys (`<<: *base`) | ✓  |
| Null (`null`, `~`, or empty value) | ✓ |
| Booleans (`true`, `false`) | ✓ |
| Integers (decimal) | ✓ |
| Floats (decimal with optional exponent) | ✓ |
| Strings (fallback for unresolved plain scalars) | ✓ |
| Duplicate mapping key rejection (per YAML 1.2 spec) | ✓ |

### Not yet supported (returns explicit errors)

| Feature | Status | Planned |
|---|---|---|
| Multi-line flow collections (flow that spans source lines) | ✗ parse-time error (single-line only) | planned |
| Explicit indent indicators (`\|2`, `\|+1`) | ✗ parse-time error (auto-detect only) | planned |
| Tags (`!!int`, `!Custom`) | ✗ `Unsupported` | planned |
| Complex keys (map as key) | ✗ parse-time error | planned |
| YAML 1.1 boolean variants (`yes`/`no`/`on`/`off`) | ✗ not planned |  use `true`/`false` |
| YAML 1.1 octal (`0777`) | ✗ not planned |  use `0o777` |

**Some features are "not planned":** YAML 1.1 has complexities with the "Norway problem", implicit octals, loose boolean literals and others that YAML 1.2 fixes, and we follow 1.2.

## Installation

```sh

gleam add yamleam

```

## Quick example

```gleam
import gleam/dynamic/decode
import yamleam

pub type Config {
  Config(name: String, port: Int, debug: Bool)
}

pub fn load_config() -> Result(Config, yamleam.YamlError) {
  let source = "
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

### Working with the raw tree

If you need the typed node tree directly without a decoder:

```gleam
import yamleam

pub fn main() {
  let assert Ok(tree) = yamleam.parse_raw("
title: Example
items:
  - alpha
  - beta
")
  // tree is a YamlNode.YamlMap([
  //   #("title", YamlString("Example")),
  //   #("items", YamlList([YamlString("alpha"), YamlString("beta")])),
  // ])
}
```

### Multi-document streams

Parse a stream containing several documents separated by `---`:

```gleam
import yamleam

pub fn main() {
  let source = "
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
  let assert Ok(documents) = yamleam.parse_documents_raw(source)
  // documents is List(YamlNode) — one entry per document.
}
```

`parse_documents(source, decoder)` runs a decoder against each document and returns `List(a)`.

`parse_raw` and `parse` are single-document APIs. If the input contains more than one document, they return a `ParseError` instead of silently discarding the remainder of the stream.

### Anchors, aliases, and merge keys

The classic CI / DRY pattern:

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

Parses cleanly: `job_a` ends up with all four entries from `defaults` plus its own `command`. `job_b` overrides `timeout` while keeping the other defaults. Local explicit keys always win over merged keys with the same name.

### Handling unsupported features

When yamleam encounters a feature it doesn't yet support, it returns a clear error rather than parsing incorrectly:

```gleam
import yamleam

pub fn main() {
  // Tags ('!!int', '!Custom') are not yet supported.
  let source = "value: !!str 42"
  case yamleam.parse_raw(source) {
    Ok(_) -> Nil
    Error(yamleam.Unsupported(feature: f, line: _, column: _)) -> {
      // f = "tags ('!type') — planned for v0.6"
      let _ = f
      Nil
    }
    Error(_) -> {
      // parse errors, etc.
      Nil
    }
  }
}
```

## Design philosophy

### 1. Deliberate partial coverage 

The YAML 1.2 specification is large. Most existing YAML libraries either aim for full spec compliance (taking substantial work and containing many rare-edge-case bugs) or implement a subset without communicating it.

yamleam picks **an explicit subset, intentionally documented, with clear errors**, that we believe serves a substantial map of use cases.

### 2. Decoder API mirrors `gleam_json`

Gleam users already know how to decode dynamic JSON, and keeping this new mental model for YAML seems aligned with the language's philosophy. yamleam's `parse(source, decoder)` takes a standard `gleam/dynamic/decode` decoder, the same kind `gleam_json.parse` takes.

### 3. Readability before performance

YAML parsing is almost never the performance bottleneck in any real system. yamleam optimizes for clarity of implementation over raw speed. Once the parser is correct and covers a meaningful subset, performance work can happen as a separate effort.

### 4. Pure Gleam

yamleam is written entirely in Gleam — no Erlang FFI, no C NIFs, no external tools. `gleam build` is enough. The per-document anchor table is a plain `dict.Dict(String, YamlNode)` threaded explicitly through the parser as a state parameter, with the lexical scope of "fresh table at the start of each document, accumulated as anchors are encountered, never escaping the parser."

### 5. Tested against realistic shapes

The test suite covers the YAML shapes that appear in real-world configs, manifests, and rulesets — block mappings with embedded scripts, sequences of inline mappings, multi-document streams, anchors with merge keys in the CI/template pattern, flow collections inside block context, and so on. As yamleam matures, we'll continue adding fixtures from real production sources to catch the edge cases that synthetic tests miss.

## Untrusted input

yamleam is designed for parsing YAML you control or that comes from a trusted source. **It is not hardened for parsing arbitrary documents of unverified provenance.**

Specifically, the parser does not enforce limits on:

- **Document size** — `parse_raw` accepts any string and walks it eagerly. A very large document will consume memory and CPU proportional to its size.
- **Nesting depth** — block structure is parsed by recursive descent without a depth budget. A pathologically deeply-nested document can cause stack growth or long parse times.

If you need to parse YAML received from untrusted sources, enforce **input size and timeout limits at your trust boundary** before calling yamleam. Equip the process with a wall-clock timeout.

## Roadmap

See [ROADMAP.md](ROADMAP.md) for the phased implementation plan and long-term coverage goals.

### Released

- **v0.1** ✓ block-style mappings, sequences, plain and quoted scalars, decoder layer
- **v0.1.1** ✓ scientific-exponent crash fix, duplicate-key rejection
- **v0.2** ✓ literal block scalars (`\|`, `\|-`, `\|+`)
- **v0.3** ✓ folded block scalars (`>`, `>-`, `>+`) + multi-document streams (`---`, `...`)
- **v0.5** ✓ flow-style collections (`[…]`, `{…}`) + anchors / aliases (`&`, `*`) + merge keys (`<<`)
- **v1.0** ✓ stable API for the documented subset (`YamlNode`, `YamlError`, `parse`, `parse_raw`, `parse_documents`, `parse_documents_raw`)

### Planned

- **v0.6** — tags (`!!str`, `!Custom`), explicit indent indicators (`\|2`, `>+1`), multi-line flow collections
- **v0.7** — complex keys (map-as-key), additional double-quoted escapes (`\u`, `\x`)

## Contributing

Contributions are welcome. Priority areas:

- **Real-world YAML fixtures** — if you have YAML files from production systems that yamleam can't yet parse, add them to `test/fixtures/` and open an issue
- **Error message quality** — we want error messages to tell users exactly what went wrong and where
- **Documentation** — examples, edge cases, migration guides from yamerl

Please open an issue before starting significant feature work so we can align on scope and ensure your effort lands in a version we're targeting.

## Development

```sh
gleam test       # Run the test suite
gleam build      # Compile the library
gleam docs build # Build HTML docs
```

## License

Apache-2.0.

## Acknowledgements

Thanks to the maintainers of Gleam, `yamerl`, `yaml-rust`, and `ocaml-yaml`.
