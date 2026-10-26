//// Flow collections that span several lines, and JSON documents.

import gleam/dynamic/decode
import gleeunit/should
import yamleam
import yamleam/error.{ParseError}
import yamleam/node.{
  YamlBool, YamlFloat, YamlInt, YamlList, YamlMap, YamlNull, YamlString,
}

pub fn sequence_across_lines_test() {
  "items: [
  a,
  b,
  c
]
next: 1"
  |> yamleam.parse_raw
  |> should.equal(
    Ok(
      YamlMap([
        #(
          "items",
          YamlList([YamlString("a"), YamlString("b"), YamlString("c")]),
        ),
        #("next", YamlInt(1)),
      ]),
    ),
  )
}

pub fn mapping_across_lines_test() {
  "env: {
  FOO: bar,
  N: 2
}"
  |> yamleam.parse_raw
  |> should.equal(
    Ok(
      YamlMap([
        #("env", YamlMap([#("FOO", YamlString("bar")), #("N", YamlInt(2))])),
      ]),
    ),
  )
}

pub fn comments_and_blank_lines_inside_test() {
  "ports: [
  80,   # http

  # tls next
  443
]  # done"
  |> yamleam.parse_raw
  |> should.equal(
    Ok(YamlMap([#("ports", YamlList([YamlInt(80), YamlInt(443)]))])),
  )
}

pub fn nested_collections_across_lines_test() {
  "matrix: {
  os: [linux,
    macos],
  otp: [27, 28]
}"
  |> yamleam.parse_raw
  |> should.equal(
    Ok(
      YamlMap([
        #(
          "matrix",
          YamlMap([
            #("os", YamlList([YamlString("linux"), YamlString("macos")])),
            #("otp", YamlList([YamlInt(27), YamlInt(28)])),
          ]),
        ),
      ]),
    ),
  )
}

pub fn sequence_item_across_lines_test() {
  "- [a,
   b]
- c"
  |> yamleam.parse_raw
  |> should.equal(
    Ok(
      YamlList([
        YamlList([YamlString("a"), YamlString("b")]),
        YamlString("c"),
      ]),
    ),
  )
}

pub fn lines_after_a_multi_line_collection_keep_their_numbers_test() {
  let assert Error(ParseError(line: 3, ..)) =
    yamleam.parse_raw(
      "a: [1,
  2]
b: c: d",
    )
}

pub fn error_inside_collection_points_at_its_line_test() {
  "m: {
  a: 1,
  a: 2
}"
  |> yamleam.parse_raw
  |> should.equal(
    Error(ParseError(
      message: "duplicate mapping key 'a' in flow mapping",
      line: 3,
      column: 3,
    )),
  )
}

pub fn document_marker_inside_collection_is_rejected_test() {
  "a: [1,
---
2]"
  |> yamleam.parse_raw
  |> should.equal(
    Error(ParseError(
      message: "document marker inside flow collection; close it with ']' or '}' first",
      line: 2,
      column: 1,
    )),
  )
}

pub fn unterminated_collection_is_rejected_test() {
  let assert Error(ParseError(
    message: "unterminated flow sequence: expected ']'",
    ..,
  )) =
    yamleam.parse_raw(
      "a: [1,
  2",
    )
}

// ── JSON ────────────────────────────────────────────────────────────────────

pub fn pretty_printed_json_test() {
  "{
  \"name\": \"yamleam\",
  \"private\": false,
  \"keywords\": [\"yaml\", \"gleam\"],
  \"author\": {\"name\": \"Ana\", \"city\": \"S\\u00e3o Paulo\"},
  \"scripts\": {
    \"test\": \"gleam test\"
  },
  \"count\": 3,
  \"ratio\": 0.5,
  \"missing\": null,
  \"empty\": [],
  \"nested\": [[1, 2], {\"k\": \"v\"}]
}
"
  |> yamleam.parse_raw
  |> should.equal(
    Ok(
      YamlMap([
        #("name", YamlString("yamleam")),
        #("private", YamlBool(False)),
        #("keywords", YamlList([YamlString("yaml"), YamlString("gleam")])),
        #(
          "author",
          YamlMap([
            #("name", YamlString("Ana")),
            #("city", YamlString("São Paulo")),
          ]),
        ),
        #("scripts", YamlMap([#("test", YamlString("gleam test"))])),
        #("count", YamlInt(3)),
        #("ratio", YamlFloat(0.5)),
        #("missing", YamlNull),
        #("empty", YamlList([])),
        #(
          "nested",
          YamlList([
            YamlList([YamlInt(1), YamlInt(2)]),
            YamlMap([#("k", YamlString("v"))]),
          ]),
        ),
      ]),
    ),
  )
}

pub fn compact_json_test() {
  "{\"a\":1,\"b\":[true,false],\"c\":{\"d\":\"e\"},\"f\":-2.5e3}"
  |> yamleam.parse_raw
  |> should.equal(
    Ok(
      YamlMap([
        #("a", YamlInt(1)),
        #("b", YamlList([YamlBool(True), YamlBool(False)])),
        #("c", YamlMap([#("d", YamlString("e"))])),
        #("f", YamlFloat(-2500.0)),
      ]),
    ),
  )
}

pub fn json_array_of_objects_with_decoder_test() {
  let source =
    "[
  {\"id\": 1, \"tags\": [\"a\"]},
  {\"id\": 2, \"tags\": []}
]"
  let item = {
    use id <- decode.field("id", decode.int)
    use tags <- decode.field("tags", decode.list(decode.string))
    decode.success(#(id, tags))
  }
  yamleam.parse(source, decode.list(item))
  |> should.equal(Ok([#(1, ["a"]), #(2, [])]))
}

pub fn block_context_still_needs_space_after_colon_test() {
  let assert Error(ParseError(
    message: "':' must be followed by whitespace or end of line",
    ..,
  )) = yamleam.parse_raw("\"a\":1")
}
