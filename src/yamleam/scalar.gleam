//// Plain scalar resolution.
////
//// Converts the verbatim text of a plain (unquoted) scalar into a typed
//// `YamlNode` according to YAML 1.2 resolution rules. Quoted scalars are
//// always strings and bypass this layer entirely.
////
//// Resolution priority (first match wins):
////   1. Empty / "null" / "Null" / "NULL" / "~"  →  YamlNull
////   2. "true"  / "True"  / "TRUE"               →  YamlBool(True)
////   3. "false" / "False" / "FALSE"              →  YamlBool(False)
////   4. Decimal integer (optional sign)          →  YamlInt
////   5. Decimal float (optional sign, exponent)  →  YamlFloat
////   6. Otherwise                                 →  YamlString
////
//// `classify` sorts the text into these kinds and keeps a number's text
//// (`ExactNumber`); `resolve_number` turns that text into `YamlInt` or
//// `YamlFloat`. `resolve` is the two together.
////
//// Following YAML 1.2, the YAML 1.1 boolean variants ("yes", "no", "on",
//// "off") and leading-zero octals ("0777") resolve as strings. Hex and
//// octal integers ("0x1F", "0o17") and the special floats (".inf",
//// ".nan") currently resolve as strings too.

import gleam/float
import gleam/int
import gleam/string
import yamleam/node.{
  type ExactNode, type YamlNode, ExactBool, ExactNull, ExactNumber, ExactString,
  YamlBool, YamlFloat, YamlInt, YamlNull, YamlString,
}

pub fn resolve(text: String) -> YamlNode {
  case classify(text) {
    ExactNull -> YamlNull
    ExactBool(b) -> YamlBool(b)
    ExactNumber(_) -> resolve_number(text)
    _ -> YamlString(text)
  }
}

/// Sort a plain scalar into null, bool, number or string. A number keeps
/// its text: it is an `ExactNumber` exactly when `resolve` would make it a
/// `YamlInt` or a `YamlFloat`.
pub fn classify(text: String) -> ExactNode {
  case text {
    "" | "null" | "Null" | "NULL" | "~" -> ExactNull
    "true" | "True" | "TRUE" -> ExactBool(True)
    "false" | "False" | "FALSE" -> ExactBool(False)
    _ ->
      case try_int(text) {
        Ok(_) -> ExactNumber(text)
        Error(_) ->
          case try_float(text) {
            Ok(_) -> ExactNumber(text)
            Error(_) -> ExactString(text)
          }
      }
  }
}

/// The `YamlInt` or `YamlFloat` for a number's text, which `classify`
/// accepted as an `ExactNumber`. Any other text is a `YamlString`.
pub fn resolve_number(text: String) -> YamlNode {
  case try_int(text) {
    Ok(i) -> YamlInt(i)
    Error(_) ->
      case try_float(text) {
        Ok(f) -> YamlFloat(f)
        Error(_) -> YamlString(text)
      }
  }
}

/// Try to parse a strict decimal integer with optional leading sign.
/// Rejects leading zeros (other than the value `0` itself) so values like
/// `"01234"` resolve to a string instead of an int — these often represent
/// account numbers, postal codes, etc., and should not be silently
/// numeric-converted.
fn try_int(text: String) -> Result(Int, Nil) {
  case text {
    "" -> Error(Nil)
    "0" -> Ok(0)
    "+0" -> Ok(0)
    "-0" -> Ok(0)
    _ -> {
      // Strip optional sign and check the rest is digits with no leading zero
      let #(sign_ok, body) = strip_sign(text)
      case sign_ok && all_digits(body) && !leading_zero(body) {
        True -> int.parse(text)
        False -> Error(Nil)
      }
    }
  }
}

fn strip_sign(text: String) -> #(Bool, String) {
  case string.starts_with(text, "+") || string.starts_with(text, "-") {
    True -> #(True, string.drop_start(text, 1))
    False -> #(True, text)
  }
}

fn all_digits(text: String) -> Bool {
  case text {
    "" -> False
    _ -> string.to_graphemes(text) |> list_all(is_ascii_digit)
  }
}

fn list_all(items: List(a), pred: fn(a) -> Bool) -> Bool {
  case items {
    [] -> True
    [h, ..t] ->
      case pred(h) {
        True -> list_all(t, pred)
        False -> False
      }
  }
}

fn is_ascii_digit(g: String) -> Bool {
  case g {
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    _ -> False
  }
}

fn leading_zero(text: String) -> Bool {
  case string.first(text) {
    Ok("0") -> string.length(text) > 1
    _ -> False
  }
}

/// Try to parse a decimal float. Allows optional sign, optional fractional
/// part, and optional exponent. The Gleam stdlib `float.parse` requires
/// both an integer part and a fractional part with a `.` between them, so
/// we normalize first by adding `.0` to bare integers (which we know are
/// not bare integers because `try_int` already failed) and accepting
/// scientific notation manually.
fn try_float(text: String) -> Result(Float, Nil) {
  case float.parse(text) {
    Ok(f) ->
      case is_finite(f) {
        True -> Ok(f)
        False -> Error(Nil)
      }
    Error(_) -> try_float_with_exponent(text)
  }
}

// Erlang's `float.parse` rejects an overflowing literal like `2.5E500`, but
// JavaScript's returns Infinity. Rejecting non-finite results here makes it
// resolve to a string on both targets. Infinity minus itself is NaN, which
// never equals 0.0.
fn is_finite(f: Float) -> Bool {
  f -. f == 0.0
}

fn try_float_with_exponent(text: String) -> Result(Float, Nil) {
  // `float.parse` needs a `.` in the mantissa, so `1e10` and `5E-3` come
  // here: the mantissa gains `.0` and the whole literal goes back to
  // `float.parse`, which rounds it correctly on both targets.
  case string.split_once(text, "e") {
    Ok(parts) -> parse_scientific(parts)
    Error(_) ->
      case string.split_once(text, "E") {
        Ok(parts) -> parse_scientific(parts)
        Error(_) -> Error(Nil)
      }
  }
}

// Float64 reaches about 1e308 and, below 1e-308, loses precision until it
// underflows to zero, where the two targets differ. Bounding the exponent
// at ±300 keeps such scalars, like `1e10000`, strings on both targets. A
// large mantissa can still overflow (`1000000000e300`); `try_float`'s
// finiteness check makes that a string too.
const max_float_exponent = 300

fn parse_scientific(parts: #(String, String)) -> Result(Float, Nil) {
  let #(mantissa_text, exponent_text) = parts
  let mantissa = case float.parse(mantissa_text), int.parse(mantissa_text) {
    Ok(_), _ -> Ok(mantissa_text)
    _, Ok(_) -> Ok(mantissa_text <> ".0")
    Error(_), Error(_) -> Error(Nil)
  }
  case mantissa, parse_exponent(exponent_text) {
    Ok(m), Ok(e) ->
      case int.absolute_value(e) <= max_float_exponent {
        True ->
          case float.parse(m <> "e" <> int.to_string(e)) {
            Ok(f) ->
              case is_finite(f) {
                True -> Ok(f)
                False -> Error(Nil)
              }
            Error(_) -> Error(Nil)
          }
        False -> Error(Nil)
      }
    _, _ -> Error(Nil)
  }
}

/// An exponent is an optional sign and at least one digit, so `1e+-5` and
/// `1e5x` are not floats.
fn parse_exponent(text: String) -> Result(Int, Nil) {
  let digits = case text {
    "+" <> rest | "-" <> rest -> rest
    _ -> text
  }
  case all_digits(digits) {
    True -> int.parse(text)
    False -> Error(Nil)
  }
}
