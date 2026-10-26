//// Double-quoted scalars: the YAML 1.2 escape set (§5.7) and line
//// folding (§7.3.1).

import gleeunit/should
import yamleam
import yamleam/error.{ParseError}
import yamleam/node.{YamlMap, YamlString}

fn value(source: String) -> Result(String, yamleam.YamlError) {
  case yamleam.parse_raw("v: " <> source) {
    Ok(YamlMap([#("v", YamlString(s))])) -> Ok(s)
    Ok(_) -> Error(ParseError(message: "unexpected tree", line: 0, column: 0))
    Error(e) -> Error(e)
  }
}

// ── Escapes ─────────────────────────────────────────────────────────────────

pub fn single_character_escapes_test() {
  value("\"\\0\\a\\b\\t\\n\\v\\f\\r\\e\\ \\\"\\/\\\\\\N\\_\\L\\P\"")
  |> should.equal(Ok(
    "\u{0000}\u{0007}\u{0008}\t\n\u{000B}\u{000C}\r\u{001B} \"/\\\u{0085}\u{00A0}\u{2028}\u{2029}",
  ))
}

pub fn escaped_tab_character_test() {
  value("\"a\\\tb\"") |> should.equal(Ok("a\tb"))
}

pub fn hex_escape_test() {
  value("\"\\x41\\x7e\"") |> should.equal(Ok("A~"))
}

pub fn unicode_escapes_test() {
  value("\"caf\\u00e9\"") |> should.equal(Ok("café"))
  value("\"\\u00E9\\U0001F600\"") |> should.equal(Ok("é😀"))
}

pub fn unknown_escape_is_rejected_test() {
  value("\"a\\qb\"")
  |> should.equal(
    Error(ParseError(
      message: "invalid escape '\\q' in double-quoted string",
      line: 1,
      column: 6,
    )),
  )
}

pub fn short_hex_escape_is_rejected_test() {
  let assert Error(ParseError(
    message: "invalid escape '\\x' in double-quoted string",
    ..,
  )) = value("\"\\x4\"")
  let assert Error(ParseError(
    message: "invalid escape '\\u' in double-quoted string",
    ..,
  )) = value("\"\\u12G4\"")
}

pub fn surrogate_escape_is_rejected_test() {
  let assert Error(ParseError(..)) = value("\"\\uD800\"")
}

pub fn escape_followed_by_more_text_test() {
  value("\"line1\\nline2\\ttab\"") |> should.equal(Ok("line1\nline2\ttab"))
}

// ── Line folding ────────────────────────────────────────────────────────────

pub fn single_break_folds_to_space_test() {
  value("\"first\n  second\"") |> should.equal(Ok("first second"))
}

pub fn trailing_white_space_before_break_is_dropped_test() {
  value("\"first   \n  second\"") |> should.equal(Ok("first second"))
}

pub fn empty_line_becomes_newline_test() {
  value("\"first\n\n  second\"") |> should.equal(Ok("first\nsecond"))
  value("\"first\n\n   \n  second\"") |> should.equal(Ok("first\n\nsecond"))
}

pub fn escaped_line_break_joins_without_space_test() {
  value("\"abc\\\n  def\"") |> should.equal(Ok("abcdef"))
}

pub fn escaped_white_space_before_break_is_kept_test() {
  value("\"a\\ \n b\"") |> should.equal(Ok("a  b"))
  value("\"a\\t\n b\"") |> should.equal(Ok("a\t b"))
}

pub fn spaces_inside_a_line_are_kept_test() {
  value("\"a  b \"") |> should.equal(Ok("a  b "))
}

pub fn folded_string_followed_by_sibling_key_test() {
  yamleam.parse_raw(
    "a: \"one
  two\"
b: 2",
  )
  |> should.equal(
    Ok(
      YamlMap([
        #("a", YamlString("one two")),
        #("b", node.YamlInt(2)),
      ]),
    ),
  )
}

pub fn unterminated_string_is_rejected_test() {
  let assert Error(ParseError(message: "unterminated double-quoted string", ..)) =
    value("\"never closed\n  still open")
}
