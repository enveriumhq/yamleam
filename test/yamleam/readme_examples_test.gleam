//// The README's examples, compiled and checked. Keep each test in step
//// with the snippet it mirrors.

import gleam/dynamic/decode
import gleam/int
import gleeunit/should
import yamleam
import yamleam/error.{DecodeError, ParseError, Unsupported}
import yamleam/exact
import yamleam/node.{
  ExactMap, ExactNumber, YamlBool, YamlFloat, YamlInt, YamlList, YamlMap,
  YamlNull, YamlString,
}

// ── Quick start ─────────────────────────────────────────────────────────────

pub type Config {
  Config(name: String, port: Int, debug: Bool)
}

fn load_config() -> Result(Config, yamleam.YamlError) {
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

pub fn quick_start_test() {
  load_config()
  |> should.equal(Ok(Config(name: "my-service", port: 8080, debug: True)))
}

// ── The raw tree ────────────────────────────────────────────────────────────

pub fn raw_tree_test() {
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

// ── Compact lists ───────────────────────────────────────────────────────────

pub fn compact_lists_test() {
  let compact =
    "
spec:
  containers:
  - name: web
    ports:
    - containerPort: 8080
"
  let indented =
    "
spec:
  containers:
    - name: web
      ports:
        - containerPort: 8080
"
  let assert Ok(tree) = yamleam.parse_raw(compact)
  yamleam.parse_raw(indented) |> should.equal(Ok(tree))
}

// ── JSON is YAML ────────────────────────────────────────────────────────────

fn package_name(json: String) -> Result(String, yamleam.YamlError) {
  yamleam.parse(json, decode.at(["name"], decode.string))
}

pub fn json_is_yaml_test() {
  let json =
    "{
  \"name\": \"yamleam\",
  \"keywords\": [\"yaml\", \"gleam\"],
  \"author\": {\"city\": \"S\\u00e3o Paulo\"}
}"
  package_name(json) |> should.equal(Ok("yamleam"))

  let assert Ok(YamlMap([_, _, #("author", author)])) = yamleam.parse_raw(json)
  author |> should.equal(YamlMap([#("city", YamlString("São Paulo"))]))
}

pub fn flow_across_lines_test() {
  yamleam.parse_raw(
    "
args: [
  --port=8080,
  --verbose,
]
",
  )
  |> should.equal(
    Ok(
      YamlMap([
        #(
          "args",
          YamlList([YamlString("--port=8080"), YamlString("--verbose")]),
        ),
      ]),
    ),
  )
}

// ── Multi-document streams ──────────────────────────────────────────────────

const stream =
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

fn kinds() -> Result(List(String), yamleam.YamlError) {
  yamleam.parse_documents(stream, decode.at(["kind"], decode.string))
}

pub fn multi_document_test() {
  kinds() |> should.equal(Ok(["ConfigMap", "Service", "Deployment"]))
}

pub fn single_document_api_rejects_stream_test() {
  let assert Error(ParseError(..)) = yamleam.parse_raw(stream)
}

// ── Anchors, aliases and merge keys ─────────────────────────────────────────

pub fn anchors_and_merge_keys_test() {
  let source =
    "
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
"
  let assert Ok(YamlMap([_, #("job_a", job_a), #("job_b", job_b)])) =
    yamleam.parse_raw(source)

  job_a
  |> should.equal(
    YamlMap([
      #("retries", YamlInt(3)),
      #("timeout", YamlInt(60)),
      #("notify", YamlString("ops@example.com")),
      #("command", YamlString("build")),
    ]),
  )
  job_b
  |> should.equal(
    YamlMap([
      #("retries", YamlInt(3)),
      #("timeout", YamlInt(300)),
      #("notify", YamlString("ops@example.com")),
      #("command", YamlString("test")),
    ]),
  )
}

pub fn merge_list_of_aliases_test() {
  let source =
    "
base: &base
  a: 1
extra: &extra
  b: 2
merged:
  <<: [*base, *extra]
"
  let assert Ok(YamlMap([_, _, #("merged", merged)])) =
    yamleam.parse_raw(source)
  merged |> should.equal(YamlMap([#("a", YamlInt(1)), #("b", YamlInt(2))]))
}

// ── Block scalars ───────────────────────────────────────────────────────────

pub fn block_scalars_test() {
  let source =
    "
script: |
  make build
  make test
summary: >
  Folded text joins
  into one line.
"
  yamleam.parse_raw(source)
  |> should.equal(
    Ok(
      YamlMap([
        #("script", YamlString("make build\nmake test\n")),
        #("summary", YamlString("Folded text joins into one line.\n")),
      ]),
    ),
  )
}

// ── Exact numbers ───────────────────────────────────────────────────────────

pub fn exact_numbers_test() {
  let assert Ok(ExactMap([#("rate", ExactNumber(rate))])) =
    exact.parse("rate: 0.10000000000000000555")
  rate |> should.equal("0.10000000000000000555")
}

// ── Wrapped values ──────────────────────────────────────────────────────────

pub fn wrapped_values_test() {
  let source =
    "
description: Returns the pets the caller may see,
  most recent first.

  Archived pets are left out.
note: 'Single-quoted text
  folds the same way.'
"
  yamleam.parse_raw(source)
  |> should.equal(
    Ok(
      YamlMap([
        #(
          "description",
          YamlString(
            "Returns the pets the caller may see, most recent first.\nArchived pets are left out.",
          ),
        ),
        #("note", YamlString("Single-quoted text folds the same way.")),
      ]),
    ),
  )
}

// ── Errors ──────────────────────────────────────────────────────────────────

fn describe(source: String) -> String {
  case yamleam.parse_raw(source) {
    Ok(_) -> "ok"
    Error(ParseError(message:, line:, ..)) ->
      "line " <> int.to_string(line) <> ": " <> message
    Error(Unsupported(feature:, ..)) -> "not supported: " <> feature
    Error(DecodeError(..)) -> "decoder rejected the document"
  }
}

pub fn describe_errors_test() {
  describe("a: 1") |> should.equal("ok")
  describe("a: 1\na: 2") |> should.equal("line 2: duplicate mapping key 'a'")
  describe("value: !!str 42")
  |> should.equal("not supported: tags ('!type')")
}

pub fn error_to_string_test() {
  let assert Error(err) = yamleam.parse_raw("a: 1\na: 2")
  error.to_string(err)
  |> should.equal(
    "yaml parse error at line 2, column 1: duplicate mapping key 'a'",
  )
}

pub fn decode_error_to_string_names_path_test() {
  let assert Error(err) =
    yamleam.parse(
      "spec:\n  port: http\n",
      decode.at(["spec", "port"], decode.int),
    )
  error.to_string(err)
  |> should.equal("yaml decode error at spec.port: expected Int, found String")
}

pub fn decode_error_to_string_counts_the_rest_test() {
  let decoder = {
    use name <- decode.field("name", decode.string)
    use port <- decode.field("port", decode.int)
    decode.success(#(name, port))
  }
  let assert Error(err) = yamleam.parse("name: 7\nport: x\n", decoder)
  error.to_string(err)
  |> should.equal(
    "yaml decode error at name: expected String, found Int (and 1 more)",
  )
}

// ── Scalar resolution ───────────────────────────────────────────────────────

fn resolve(text: String) -> yamleam.YamlNode {
  let assert Ok(YamlMap([#("v", value)])) = yamleam.parse_raw("v: " <> text)
  value
}

pub fn scalar_resolution_table_test() {
  resolve("null") |> should.equal(YamlNull)
  resolve("~") |> should.equal(YamlNull)
  resolve("") |> should.equal(YamlNull)
  resolve("TRUE") |> should.equal(YamlBool(True))
  resolve("False") |> should.equal(YamlBool(False))
  resolve("+3") |> should.equal(YamlInt(3))
  resolve("-17") |> should.equal(YamlInt(-17))
  resolve("0") |> should.equal(YamlInt(0))
  resolve("-0.5") |> should.equal(YamlFloat(-0.5))
  resolve("1e10") |> should.equal(YamlFloat(1.0e10))
  resolve("1.0E-3") |> should.equal(YamlFloat(1.0e-3))
  resolve("yes") |> should.equal(YamlString("yes"))
  resolve("off") |> should.equal(YamlString("off"))
  resolve("01234") |> should.equal(YamlString("01234"))
  resolve("0777") |> should.equal(YamlString("0777"))
  resolve("0x1F") |> should.equal(YamlString("0x1F"))
  resolve("0o17") |> should.equal(YamlString("0o17"))
  resolve(".inf") |> should.equal(YamlString(".inf"))
  resolve("\"123\"") |> should.equal(YamlString("123"))
}
