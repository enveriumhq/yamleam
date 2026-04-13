//// Flow-style collection tests.

import gleam/dynamic/decode
import gleeunit/should
import yamleam
import yamleam/node.{YamlBool, YamlInt, YamlList, YamlMap, YamlNull, YamlString}

// ── Flow sequences ──────────────────────────────────────────────────────────

pub fn empty_flow_seq_test() {
  yamleam.parse_raw("[]")
  |> should.equal(Ok(YamlList([])))
}

pub fn flow_seq_of_ints_test() {
  yamleam.parse_raw("[1, 2, 3]")
  |> should.equal(Ok(YamlList([YamlInt(1), YamlInt(2), YamlInt(3)])))
}

pub fn flow_seq_of_strings_test() {
  yamleam.parse_raw("[alpha, beta, gamma]")
  |> should.equal(
    Ok(YamlList([YamlString("alpha"), YamlString("beta"), YamlString("gamma")])),
  )
}

pub fn flow_seq_with_quoted_strings_test() {
  yamleam.parse_raw("[\"hello\", 'world']")
  |> should.equal(Ok(YamlList([YamlString("hello"), YamlString("world")])))
}

pub fn flow_seq_mixed_types_test() {
  yamleam.parse_raw("[42, true, null, 3.14, \"text\"]")
  |> should.equal(
    Ok(
      YamlList([
        YamlInt(42),
        YamlBool(True),
        YamlNull,
        node.YamlFloat(3.14),
        YamlString("text"),
      ]),
    ),
  )
}

pub fn flow_seq_as_mapping_value_test() {
  yamleam.parse_raw("ports: [80, 443, 8080]")
  |> should.equal(
    Ok(
      YamlMap([
        #("ports", YamlList([YamlInt(80), YamlInt(443), YamlInt(8080)])),
      ]),
    ),
  )
}

pub fn nested_flow_seqs_test() {
  yamleam.parse_raw("[[1, 2], [3, 4], [5]]")
  |> should.equal(
    Ok(
      YamlList([
        YamlList([YamlInt(1), YamlInt(2)]),
        YamlList([YamlInt(3), YamlInt(4)]),
        YamlList([YamlInt(5)]),
      ]),
    ),
  )
}

// ── Flow mappings ───────────────────────────────────────────────────────────

pub fn empty_flow_map_test() {
  yamleam.parse_raw("{}")
  |> should.equal(Ok(YamlMap([])))
}

pub fn flow_map_basic_test() {
  yamleam.parse_raw("{a: 1, b: 2}")
  |> should.equal(Ok(YamlMap([#("a", YamlInt(1)), #("b", YamlInt(2))])))
}

pub fn flow_map_with_quoted_keys_test() {
  yamleam.parse_raw("{\"name\": Alice, 'role': admin}")
  |> should.equal(
    Ok(
      YamlMap([
        #("name", YamlString("Alice")),
        #("role", YamlString("admin")),
      ]),
    ),
  )
}

pub fn flow_map_as_mapping_value_test() {
  yamleam.parse_raw("config: {timeout: 30, retries: 3}")
  |> should.equal(
    Ok(
      YamlMap([
        #(
          "config",
          YamlMap([#("timeout", YamlInt(30)), #("retries", YamlInt(3))]),
        ),
      ]),
    ),
  )
}

pub fn nested_flow_maps_test() {
  yamleam.parse_raw("{outer: {inner: value}}")
  |> should.equal(
    Ok(
      YamlMap([
        #("outer", YamlMap([#("inner", YamlString("value"))])),
      ]),
    ),
  )
}

// ── Mixed flow ──────────────────────────────────────────────────────────────

pub fn flow_seq_of_flow_maps_test() {
  // The pattern Helm and k8s use heavily.
  yamleam.parse_raw("[{key: gpu, value: \"true\"}, {key: ssd, value: \"yes\"}]")
  |> should.equal(
    Ok(
      YamlList([
        YamlMap([
          #("key", YamlString("gpu")),
          #("value", YamlString("true")),
        ]),
        YamlMap([
          #("key", YamlString("ssd")),
          #("value", YamlString("yes")),
        ]),
      ]),
    ),
  )
}

pub fn flow_map_containing_flow_seq_test() {
  yamleam.parse_raw("{tags: [a, b, c], count: 3}")
  |> should.equal(
    Ok(
      YamlMap([
        #("tags", YamlList([YamlString("a"), YamlString("b"), YamlString("c")])),
        #("count", YamlInt(3)),
      ]),
    ),
  )
}

// ── Flow inside block context ───────────────────────────────────────────────

pub fn flow_value_in_block_mapping_test() {
  let source =
    "name: my-service
ports: [80, 443]
debug: true"
  yamleam.parse_raw(source)
  |> should.equal(
    Ok(
      YamlMap([
        #("name", YamlString("my-service")),
        #("ports", YamlList([YamlInt(80), YamlInt(443)])),
        #("debug", YamlBool(True)),
      ]),
    ),
  )
}

pub fn flow_value_as_block_sequence_item_test() {
  let source =
    "- [1, 2, 3]
- [4, 5, 6]
- [7, 8, 9]"
  yamleam.parse_raw(source)
  |> should.equal(
    Ok(
      YamlList([
        YamlList([YamlInt(1), YamlInt(2), YamlInt(3)]),
        YamlList([YamlInt(4), YamlInt(5), YamlInt(6)]),
        YamlList([YamlInt(7), YamlInt(8), YamlInt(9)]),
      ]),
    ),
  )
}

pub fn flow_in_dash_inline_mapping_test() {
  // The k8s tolerations / Helm values shape.
  let source =
    "- name: app
  ports: [80, 443]
- name: db
  ports: [5432]"
  yamleam.parse_raw(source)
  |> should.equal(
    Ok(
      YamlList([
        YamlMap([
          #("name", YamlString("app")),
          #("ports", YamlList([YamlInt(80), YamlInt(443)])),
        ]),
        YamlMap([
          #("name", YamlString("db")),
          #("ports", YamlList([YamlInt(5432)])),
        ]),
      ]),
    ),
  )
}

// ── Decoder integration ─────────────────────────────────────────────────────

pub fn flow_decoded_through_decoder_test() {
  let source = "tags: [foo, bar, baz]"
  let decoder = {
    use tags <- decode.field("tags", decode.list(decode.string))
    decode.success(tags)
  }
  yamleam.parse(source, decoder)
  |> should.equal(Ok(["foo", "bar", "baz"]))
}

// ── Error cases ─────────────────────────────────────────────────────────────

pub fn unterminated_flow_seq_test() {
  case yamleam.parse_raw("[1, 2, 3") {
    Error(_) -> Nil
    Ok(_) -> should.fail()
  }
}

pub fn unterminated_flow_map_test() {
  case yamleam.parse_raw("{a: 1, b: 2") {
    Error(_) -> Nil
    Ok(_) -> should.fail()
  }
}

pub fn duplicate_flow_map_keys_rejected_test() {
  case yamleam.parse_raw("{a: 1, a: 2}") {
    Error(_) -> Nil
    Ok(_) -> should.fail()
  }
}
