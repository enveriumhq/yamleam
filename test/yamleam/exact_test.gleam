//// The exact tree: numbers keep the text they were written with.

import gleam/list
import gleeunit/should
import yamleam
import yamleam/exact
import yamleam/node.{
  ExactBool, ExactList, ExactMap, ExactNull, ExactNumber, ExactString,
}
import yamleam/scalar

fn number(source: String) -> String {
  let assert Ok(ExactMap([#("n", ExactNumber(text))])) =
    exact.parse("n: " <> source)
  text
}

// ── Numbers keep their text ─────────────────────────────────────────────────

pub fn short_decimal_keeps_its_text_test() {
  number("0.0323") |> should.equal("0.0323")
}

pub fn trailing_zero_is_kept_test() {
  number("12.50") |> should.equal("12.50")
}

pub fn signs_are_kept_test() {
  number("-0") |> should.equal("-0")
  number("+3") |> should.equal("+3")
  number("-0.5") |> should.equal("-0.5")
}

pub fn exponent_forms_are_kept_test() {
  number("+1.5e3") |> should.equal("+1.5e3")
  number("1.0E-3") |> should.equal("1.0E-3")
  number("1e10") |> should.equal("1e10")
}

pub fn digits_past_float_precision_are_kept_test() {
  number("0.10000000000000000555") |> should.equal("0.10000000000000000555")
}

pub fn integer_past_two_to_the_53_is_kept_test() {
  number("123456789012345678901234567890")
  |> should.equal("123456789012345678901234567890")
}

// ── Everything that is not a number is unchanged ────────────────────────────

pub fn quoted_number_is_a_string_test() {
  exact.parse("a: \"1.5\"\nb: '2'")
  |> should.equal(
    Ok(ExactMap([#("a", ExactString("1.5")), #("b", ExactString("2"))])),
  )
}

pub fn non_numbers_stay_strings_test() {
  ["01234", "0x1F", "0o17", ".inf", ".nan", "1e10000", "1.2.3", "yes"]
  |> list.each(fn(text) {
    scalar.classify(text) |> should.equal(ExactString(text))
  })
}

pub fn null_and_bool_test() {
  exact.parse("a: ~\nb: true\nc:")
  |> should.equal(
    Ok(
      ExactMap([
        #("a", ExactNull),
        #("b", ExactBool(True)),
        #("c", ExactNull),
      ]),
    ),
  )
}

// ── Numbers through every structure ─────────────────────────────────────────

pub fn numbers_in_flow_and_block_collections_test() {
  exact.parse("limits: [0.10, 2]\nsteps:\n  - 1.50\n  - {at: 3.0}")
  |> should.equal(
    Ok(
      ExactMap([
        #("limits", ExactList([ExactNumber("0.10"), ExactNumber("2")])),
        #(
          "steps",
          ExactList([
            ExactNumber("1.50"),
            ExactMap([#("at", ExactNumber("3.0"))]),
          ]),
        ),
      ]),
    ),
  )
}

pub fn numbers_through_anchors_aliases_and_merge_keys_test() {
  let source =
    "base: &base
  rate: 0.0323
copy: *base
derived:
  <<: *base
  cap: 12.50"
  exact.parse(source)
  |> should.equal(
    Ok(
      ExactMap([
        #("base", ExactMap([#("rate", ExactNumber("0.0323"))])),
        #("copy", ExactMap([#("rate", ExactNumber("0.0323"))])),
        #(
          "derived",
          ExactMap([
            #("rate", ExactNumber("0.0323")),
            #("cap", ExactNumber("12.50")),
          ]),
        ),
      ]),
    ),
  )
}

pub fn documents_keep_their_numbers_test() {
  exact.parse_documents("---\nn: 1.10\n---\nn: 2.20\n")
  |> should.equal(
    Ok([
      ExactMap([#("n", ExactNumber("1.10"))]),
      ExactMap([#("n", ExactNumber("2.20"))]),
    ]),
  )
}

pub fn parse_errors_match_parse_raw_test() {
  let source = "a: 1\na: 2"
  let assert Error(_) = exact.parse(source)
  exact.parse(source)
  |> map_ok(exact.to_yaml_node)
  |> should.equal(yamleam.parse_raw(source))
}

// ── The exact tree resolves to the raw tree ─────────────────────────────────

pub fn to_yaml_node_matches_parse_raw_test() {
  [
    "n: 0.0323",
    "n: -17",
    "n: 1e10",
    "n: 1.0E-3",
    "n: 1e10000",
    "n: 01234",
    "[1, 2.5, \"3\", ~, true, x]",
    "a: &a {r: 0.25}\nb:\n  <<: *a\n  s: [1.5, 2]",
    "text: |\n  1.5\n",
    "- 3.14\n- -0.5\n- +3",
  ]
  |> list.each(fn(source) {
    exact.parse(source)
    |> map_ok(exact.to_yaml_node)
    |> should.equal(yamleam.parse_raw(source))
  })
}

pub fn flow_pair_number_key_is_unchanged_test() {
  let source = "[1.50: x]"
  exact.parse(source)
  |> map_ok(exact.to_yaml_node)
  |> should.equal(yamleam.parse_raw(source))
}

fn map_ok(result: Result(a, e), f: fn(a) -> b) -> Result(b, e) {
  case result {
    Ok(value) -> Ok(f(value))
    Error(e) -> Error(e)
  }
}
