//// Line endings and byte order marks: CRLF and CR read the same as LF,
//// and a leading BOM is dropped (YAML 1.2 §5.2, §5.4).

import gleeunit/should
import yamleam
import yamleam/error.{ParseError}
import yamleam/node.{YamlInt, YamlList, YamlMap, YamlString}

pub fn crlf_nested_mapping_test() {
  "a:\r\n  b: 1\r\n  c: two\r\n"
  |> yamleam.parse_raw
  |> should.equal(
    Ok(
      YamlMap([
        #("a", YamlMap([#("b", YamlInt(1)), #("c", YamlString("two"))])),
      ]),
    ),
  )
}

pub fn crlf_sequences_test() {
  "list:\r\n- x\r\n- \"q\"\r\nindented:\r\n  - 1\r\n"
  |> yamleam.parse_raw
  |> should.equal(
    Ok(
      YamlMap([
        #("list", YamlList([YamlString("x"), YamlString("q")])),
        #("indented", YamlList([YamlInt(1)])),
      ]),
    ),
  )
}

pub fn crlf_block_scalar_content_uses_lf_test() {
  "script: |\r\n  make build\r\n  make test\r\n"
  |> yamleam.parse_raw
  |> should.equal(
    Ok(YamlMap([#("script", YamlString("make build\nmake test\n"))])),
  )
}

pub fn crlf_double_quoted_folding_test() {
  "v: \"one\r\n  two\r\n\r\n  three\"\r\n"
  |> yamleam.parse_raw
  |> should.equal(Ok(YamlMap([#("v", YamlString("one two\nthree"))])))
}

pub fn crlf_multi_document_stream_test() {
  "---\r\na: 1\r\n---\r\nb: 2\r\n"
  |> yamleam.parse_documents_raw
  |> should.equal(
    Ok([YamlMap([#("a", YamlInt(1))]), YamlMap([#("b", YamlInt(2))])]),
  )
}

pub fn cr_only_line_endings_test() {
  "a: 1\rb:\r  c: 2\r"
  |> yamleam.parse_raw
  |> should.equal(
    Ok(YamlMap([#("a", YamlInt(1)), #("b", YamlMap([#("c", YamlInt(2))]))])),
  )
}

pub fn crlf_error_positions_test() {
  "a: 1\r\nb: 2\r\na: 3\r\n"
  |> yamleam.parse_raw
  |> should.equal(
    Error(ParseError(message: "duplicate mapping key 'a'", line: 3, column: 1)),
  )
}

pub fn leading_bom_is_dropped_test() {
  "\u{FEFF}name: x\nport: 80"
  |> yamleam.parse_raw
  |> should.equal(
    Ok(YamlMap([#("name", YamlString("x")), #("port", YamlInt(80))])),
  )
}

pub fn bom_with_crlf_test() {
  "\u{FEFF}a:\r\n- 1\r\n"
  |> yamleam.parse_raw
  |> should.equal(Ok(YamlMap([#("a", YamlList([YamlInt(1)]))])))
}

pub fn bom_does_not_shift_error_columns_test() {
  let assert Error(ParseError(line: 1, column: 1, ..)) =
    yamleam.parse_raw("\u{FEFF}\tkey: 1")
}
