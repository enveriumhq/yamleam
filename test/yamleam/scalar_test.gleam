import gleeunit/should
import yamleam/node.{YamlBool, YamlFloat, YamlInt, YamlNull, YamlString}
import yamleam/scalar

pub fn empty_resolves_to_null_test() {
  scalar.resolve("") |> should.equal(YamlNull)
}

pub fn null_keyword_resolves_to_null_test() {
  scalar.resolve("null") |> should.equal(YamlNull)
  scalar.resolve("Null") |> should.equal(YamlNull)
  scalar.resolve("NULL") |> should.equal(YamlNull)
  scalar.resolve("~") |> should.equal(YamlNull)
}

pub fn true_resolves_to_bool_test() {
  scalar.resolve("true") |> should.equal(YamlBool(True))
  scalar.resolve("True") |> should.equal(YamlBool(True))
  scalar.resolve("TRUE") |> should.equal(YamlBool(True))
}

pub fn false_resolves_to_bool_test() {
  scalar.resolve("false") |> should.equal(YamlBool(False))
  scalar.resolve("False") |> should.equal(YamlBool(False))
  scalar.resolve("FALSE") |> should.equal(YamlBool(False))
}

pub fn yaml_1_1_booleans_resolve_to_string_test() {
  // YAML 1.1 booleans like "yes"/"no" are intentionally NOT recognized.
  // They resolve to strings.
  scalar.resolve("yes") |> should.equal(YamlString("yes"))
  scalar.resolve("no") |> should.equal(YamlString("no"))
  scalar.resolve("on") |> should.equal(YamlString("on"))
  scalar.resolve("off") |> should.equal(YamlString("off"))
}

pub fn integer_resolves_test() {
  scalar.resolve("0") |> should.equal(YamlInt(0))
  scalar.resolve("42") |> should.equal(YamlInt(42))
  scalar.resolve("-17") |> should.equal(YamlInt(-17))
  scalar.resolve("+3") |> should.equal(YamlInt(3))
}

pub fn leading_zero_integer_resolves_to_string_test() {
  // Common in postal codes, account numbers, etc. Don't silently convert.
  scalar.resolve("0123") |> should.equal(YamlString("0123"))
  scalar.resolve("01") |> should.equal(YamlString("01"))
}

pub fn float_resolves_test() {
  scalar.resolve("3.14") |> should.equal(YamlFloat(3.14))
  scalar.resolve("-0.5") |> should.equal(YamlFloat(-0.5))
}

pub fn scientific_float_resolves_test() {
  scalar.resolve("1e3") |> should.equal(YamlFloat(1000.0))
  scalar.resolve("1.5E2") |> should.equal(YamlFloat(150.0))
}

pub fn out_of_range_exponent_resolves_to_string_test() {
  // Float64 maxes out around 1e308. Anything larger must NOT crash —
  // it should fall through to YamlString.
  scalar.resolve("1e10000") |> should.equal(YamlString("1e10000"))
  scalar.resolve("1e-10000") |> should.equal(YamlString("1e-10000"))
  scalar.resolve("2.5E500") |> should.equal(YamlString("2.5E500"))
}

pub fn unquoted_text_resolves_to_string_test() {
  scalar.resolve("hello") |> should.equal(YamlString("hello"))
  scalar.resolve("hello world") |> should.equal(YamlString("hello world"))
  scalar.resolve("https://example.com")
  |> should.equal(YamlString("https://example.com"))
}

pub fn mixed_alphanumeric_resolves_to_string_test() {
  scalar.resolve("v1.2.3") |> should.equal(YamlString("v1.2.3"))
  scalar.resolve("user@example.com")
  |> should.equal(YamlString("user@example.com"))
}

pub fn quoted_strings_are_not_resolved_here_test() {
  // The lexer wraps quoted strings in QuotedScalar tokens, so this layer
  // never sees them. We don't have a test path that proves it directly,
  // but the parser-level test will confirm a quoted "true" stays a string.
  Nil
}
