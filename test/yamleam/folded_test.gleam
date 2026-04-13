//// Folded block scalar (`>`) tests.

import gleeunit/should
import yamleam
import yamleam/node.{YamlMap, YamlString}

pub fn folded_basic_test() {
  // Each content line in a paragraph folds to a single space.
  let source =
    "msg: >
  first line
  second line
  third line"
  yamleam.parse_raw(source)
  |> should.equal(
    Ok(YamlMap([#("msg", YamlString("first line second line third line\n"))])),
  )
}

pub fn folded_with_paragraph_break_test() {
  // Blank lines mark paragraph breaks and become literal newlines.
  let source =
    "desc: >
  first paragraph
  continues here

  second paragraph
  also continues"
  yamleam.parse_raw(source)
  |> should.equal(
    Ok(
      YamlMap([
        #(
          "desc",
          YamlString(
            "first paragraph continues here\nsecond paragraph also continues\n",
          ),
        ),
      ]),
    ),
  )
}

pub fn folded_strip_chomping_test() {
  let source =
    "msg: >-
  folded text"
  yamleam.parse_raw(source)
  |> should.equal(Ok(YamlMap([#("msg", YamlString("folded text"))])))
}

pub fn folded_keep_chomping_test() {
  let source =
    "msg: >+
  keep me


next: value"
  yamleam.parse_raw(source)
  |> should.equal(
    Ok(
      YamlMap([
        #("msg", YamlString("keep me\n\n\n")),
        #("next", YamlString("value")),
      ]),
    ),
  )
}

pub fn folded_with_more_indented_line_test() {
  // More-indented lines preserve their newline (not folded).
  let source =
    "text: >
  normal fold line
   more indented
  back to normal"
  yamleam.parse_raw(source)
  |> should.equal(
    Ok(
      YamlMap([
        #(
          "text",
          YamlString("normal fold line\n more indented\nback to normal\n"),
        ),
      ]),
    ),
  )
}

pub fn folded_in_sequence_item_test() {
  let source =
    "- description: >
    a long description
    that folds nicely
  id: s1"
  yamleam.parse_raw(source)
  |> should.equal(
    Ok(
      node.YamlList([
        YamlMap([
          #("description", YamlString("a long description that folds nicely\n")),
          #("id", YamlString("s1")),
        ]),
      ]),
    ),
  )
}
