//// Anchor, alias, and merge-key tests.

import gleam/dynamic/decode
import gleeunit/should
import yamleam
import yamleam/error.{ParseError}
import yamleam/node.{YamlInt, YamlList, YamlMap, YamlString}

// ── Basic anchors and aliases ───────────────────────────────────────────────

pub fn anchor_and_alias_simple_scalar_test() {
  let source =
    "first: &name Alice
second: *name"
  yamleam.parse_raw(source)
  |> should.equal(
    Ok(
      YamlMap([
        #("first", YamlString("Alice")),
        #("second", YamlString("Alice")),
      ]),
    ),
  )
}

pub fn anchor_with_int_value_test() {
  let source =
    "x: &num 42
y: *num
z: *num"
  yamleam.parse_raw(source)
  |> should.equal(
    Ok(
      YamlMap([
        #("x", YamlInt(42)),
        #("y", YamlInt(42)),
        #("z", YamlInt(42)),
      ]),
    ),
  )
}

pub fn anchor_on_nested_block_test() {
  let source =
    "base: &base
  name: app
  port: 8080
copy: *base"
  yamleam.parse_raw(source)
  |> should.equal(
    Ok(
      YamlMap([
        #(
          "base",
          YamlMap([#("name", YamlString("app")), #("port", YamlInt(8080))]),
        ),
        #(
          "copy",
          YamlMap([#("name", YamlString("app")), #("port", YamlInt(8080))]),
        ),
      ]),
    ),
  )
}

pub fn anchor_on_sequence_test() {
  let source =
    "items: &items
  - one
  - two
  - three
copy: *items"
  yamleam.parse_raw(source)
  |> should.equal(
    Ok(
      YamlMap([
        #(
          "items",
          YamlList([
            YamlString("one"),
            YamlString("two"),
            YamlString("three"),
          ]),
        ),
        #(
          "copy",
          YamlList([
            YamlString("one"),
            YamlString("two"),
            YamlString("three"),
          ]),
        ),
      ]),
    ),
  )
}

pub fn anchor_in_sequence_item_test() {
  let source =
    "- &first one
- two
- *first"
  yamleam.parse_raw(source)
  |> should.equal(
    Ok(
      YamlList([
        YamlString("one"),
        YamlString("two"),
        YamlString("one"),
      ]),
    ),
  )
}

pub fn anchor_on_dash_with_inline_mapping_test() {
  let source =
    "- &item
  id: a
  value: 1
- *item"
  yamleam.parse_raw(source)
  |> should.equal(
    Ok(
      YamlList([
        YamlMap([#("id", YamlString("a")), #("value", YamlInt(1))]),
        YamlMap([#("id", YamlString("a")), #("value", YamlInt(1))]),
      ]),
    ),
  )
}

// ── Anchors in flow context ─────────────────────────────────────────────────

pub fn anchor_in_flow_seq_test() {
  let source = "items: [&a 1, 2, *a]"
  yamleam.parse_raw(source)
  |> should.equal(
    Ok(
      YamlMap([
        #("items", YamlList([YamlInt(1), YamlInt(2), YamlInt(1)])),
      ]),
    ),
  )
}

pub fn anchor_in_flow_map_test() {
  let source = "{a: &x 10, b: *x}"
  yamleam.parse_raw(source)
  |> should.equal(Ok(YamlMap([#("a", YamlInt(10)), #("b", YamlInt(10))])))
}

// ── Merge keys ──────────────────────────────────────────────────────────────

pub fn merge_key_basic_test() {
  let source =
    "base: &base
  host: localhost
  port: 5432
prod:
  <<: *base
  host: prod.example.com"
  yamleam.parse_raw(source)
  |> should.equal(
    Ok(
      YamlMap([
        #(
          "base",
          YamlMap([
            #("host", YamlString("localhost")),
            #("port", YamlInt(5432)),
          ]),
        ),
        #(
          "prod",
          YamlMap([
            #("host", YamlString("prod.example.com")),
            #("port", YamlInt(5432)),
          ]),
        ),
      ]),
    ),
  )
}

pub fn merge_key_local_keys_take_precedence_test() {
  // The merge key brings in entries from the alias, but any keys
  // explicitly defined in the local mapping override those.
  let source =
    "defaults: &d
  a: 1
  b: 2
  c: 3
override:
  a: 100
  <<: *d"
  yamleam.parse_raw(source)
  |> should.equal(
    Ok(
      YamlMap([
        #(
          "defaults",
          YamlMap([
            #("a", YamlInt(1)),
            #("b", YamlInt(2)),
            #("c", YamlInt(3)),
          ]),
        ),
        #(
          "override",
          YamlMap([
            #("a", YamlInt(100)),
            #("b", YamlInt(2)),
            #("c", YamlInt(3)),
          ]),
        ),
      ]),
    ),
  )
}

pub fn merge_key_with_list_of_aliases_test() {
  // YAML 1.1 merge spec also allows a list of mapping aliases. Merged
  // keys are added at the merge point in source order; explicit keys
  // declared after the merge appear after the merged keys.
  let source =
    "a: &a
  x: 1
b: &b
  y: 2
combined:
  <<: [*a, *b]
  z: 3"
  yamleam.parse_raw(source)
  |> should.equal(
    Ok(
      YamlMap([
        #("a", YamlMap([#("x", YamlInt(1))])),
        #("b", YamlMap([#("y", YamlInt(2))])),
        #(
          "combined",
          YamlMap([
            #("x", YamlInt(1)),
            #("y", YamlInt(2)),
            #("z", YamlInt(3)),
          ]),
        ),
      ]),
    ),
  )
}

// ── Decoder integration ─────────────────────────────────────────────────────

pub fn alias_decoded_through_decoder_test() {
  let source =
    "common: &common
  user: alice
  email: alice@example.com
profile: *common"

  let decoder = {
    use user <- decode.field("user", decode.string)
    use email <- decode.field("email", decode.string)
    decode.success(#(user, email))
  }

  let outer = {
    use profile <- decode.field("profile", decoder)
    decode.success(profile)
  }

  yamleam.parse(source, outer)
  |> should.equal(Ok(#("alice", "alice@example.com")))
}

// ── Error cases ─────────────────────────────────────────────────────────────

pub fn unknown_alias_rejected_test() {
  let source = "key: *missing"
  case yamleam.parse_raw(source) {
    Error(_) -> Nil
    Ok(_) -> should.fail()
  }
}

pub fn merge_key_error_reports_source_position_test() {
  let source =
    "target:
  <<: 42"

  case yamleam.parse_raw(source) {
    Error(ParseError(message: _, line: 2, column: 3)) -> Nil
    _ -> should.fail()
  }
}

pub fn anchor_scope_resets_between_documents_test() {
  // Anchor defined in document 1 must NOT be visible in document 2.
  let source =
    "---
key: &name value
---
key2: *name"
  case yamleam.parse_documents_raw(source) {
    Error(_) -> Nil
    Ok(_) -> should.fail()
  }
}

pub fn ci_template_pattern_test() {
  // The classic CI / DRY pattern. Merged keys appear in their order
  // from the alias; explicit keys declared after the merge are appended
  // (or replace in-place if the key already exists from the merge).
  let source =
    "defaults: &defaults
  retries: 3
  timeout: 60
  notify: ops@example.com

job_a:
  <<: *defaults
  command: build

job_b:
  <<: *defaults
  command: test
  timeout: 300"

  yamleam.parse_raw(source)
  |> should.equal(
    Ok(
      YamlMap([
        #(
          "defaults",
          YamlMap([
            #("retries", YamlInt(3)),
            #("timeout", YamlInt(60)),
            #("notify", YamlString("ops@example.com")),
          ]),
        ),
        #(
          "job_a",
          YamlMap([
            #("retries", YamlInt(3)),
            #("timeout", YamlInt(60)),
            #("notify", YamlString("ops@example.com")),
            #("command", YamlString("build")),
          ]),
        ),
        #(
          "job_b",
          YamlMap([
            #("retries", YamlInt(3)),
            // timeout was 60 from merge but explicit `timeout: 300`
            // overrides it in place, keeping the original position.
            #("timeout", YamlInt(300)),
            #("notify", YamlString("ops@example.com")),
            #("command", YamlString("test")),
          ]),
        ),
      ]),
    ),
  )
}
