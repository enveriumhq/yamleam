//// Plain and single-quoted scalars that span several lines.

import gleam/dynamic/decode
import yamleam
import yamleam/error.{ParseError}
import yamleam/node.{YamlInt, YamlList, YamlMap, YamlString}

const key_error = "unexpected ':' after a plain scalar that spans lines; a mapping key must fit on one line"

pub fn plain_value_folds_into_one_line_test() {
  let assert Ok(YamlMap([
    #("description", YamlString("Returns the list of pets the caller may see.")),
    #("next", YamlInt(1)),
  ])) =
    yamleam.parse_raw(
      "description: Returns the list of pets
  the caller may see.
next: 1",
    )
}

pub fn empty_lines_become_line_breaks_test() {
  let assert Ok(YamlMap([
    #("text", YamlString("first paragraph\nsecond\n\nthird")),
    #("next", YamlInt(1)),
  ])) =
    yamleam.parse_raw(
      "text: first
  paragraph

  second   


  third

next: 1",
    )
}

pub fn value_on_the_line_after_its_key_test() {
  let assert Ok(YamlMap([#("summary", YamlString("one two three"))])) =
    yamleam.parse_raw(
      "summary:
  one
  two
    three",
    )
}

pub fn sequence_item_continues_test() {
  let assert Ok(YamlList([YamlString("install the - dependencies"), YamlString("test")])) =
    yamleam.parse_raw(
      "- install the
  - dependencies
- test",
    )
}

pub fn value_in_a_sequence_item_mapping_test() {
  let assert Ok(YamlList([
    YamlMap([#("name", YamlString("build the image")), #("run", YamlString("make"))]),
  ])) =
    yamleam.parse_raw(
      "- name: build
    the image
  run: make",
    )
}

pub fn continuation_at_the_key_indent_is_not_part_of_the_value_test() {
  let assert Error(ParseError(line: 2, ..)) =
    yamleam.parse_raw(
      "- name: build
  the image",
    )
}

pub fn root_scalar_continues_at_any_indent_test() {
  let assert Ok(YamlString("just some text")) =
    yamleam.parse_raw("just some\ntext")
}

pub fn continued_text_is_always_a_string_test() {
  let assert Ok(YamlMap([#("n", YamlString("1 2"))])) =
    yamleam.parse_raw("n: 1\n  2")
}

pub fn decoder_sees_the_folded_value_test() {
  let assert Ok("a long title") =
    yamleam.parse("title: a long\n  title", decode.at(["title"], decode.string))
}

pub fn flow_sequence_item_continues_test() {
  let assert Ok(YamlList([YamlString("a b"), YamlString("c")])) =
    yamleam.parse_raw("[a\n b,\n c\n]")
}

pub fn comment_ends_the_scalar_test() {
  let assert Error(ParseError(line: 3, ..)) =
    yamleam.parse_raw("key: a\n  # note\n  b")
  let assert Error(ParseError(line: 2, ..)) =
    yamleam.parse_raw("key: a # note\n  b")
}

pub fn document_marker_ends_the_scalar_test() {
  let assert Ok([YamlString("a"), YamlString("b")]) =
    yamleam.parse_documents_raw("a\n---\nb")
}

pub fn key_spanning_lines_is_an_error_test() {
  let assert Error(ParseError(message: m1, line: 2, column: 2)) =
    yamleam.parse_raw("a\nb: c")
  let assert True = m1 == key_error
  let assert Error(ParseError(message: m2, line: 2, column: 4)) =
    yamleam.parse_raw("key: a\n  b: c")
  let assert True = m2 == key_error
  let assert Error(ParseError(message: m3, line: 2, column: 3)) =
    yamleam.parse_raw("{a\n b: c}")
  let assert True = m3 == key_error
}

pub fn lines_after_a_continued_scalar_keep_their_numbers_test() {
  let assert Error(ParseError(message: "duplicate mapping key 'a'", line: 5, ..)) =
    yamleam.parse_raw("a: one\n  two\n\n  three\na: again")
}

pub fn single_quoted_folds_test() {
  let assert Ok(YamlMap([#("msg", YamlString("it's a\nlong one")), #("next", YamlInt(1))])) =
    yamleam.parse_raw("msg: 'it''s a   \n\n    long one'\nnext: 1")
}

pub fn single_quoted_spaces_inside_a_line_are_kept_test() {
  let assert Ok(YamlString("a  b c")) = yamleam.parse_raw("'a  b\n c'")
}

pub fn unterminated_single_quoted_points_at_its_last_line_test() {
  let assert Error(ParseError(
    message: "unterminated single-quoted string",
    line: 2,
    ..,
  )) = yamleam.parse_raw("msg: 'open\n  still open\n\n")
}
