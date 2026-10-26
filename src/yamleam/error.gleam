//// Error type for yamleam.
////
//// `YamlError` distinguishes three failure modes:
//// - `ParseError` — the source is not valid YAML, or uses a construct
////   outside the supported set; includes a free-form message and the
////   1-indexed line/column of the offending character
//// - `Unsupported` — the source uses a YAML feature outside the
////   supported set; the `feature` field names what was encountered
//// - `DecodeError` — the source parsed correctly but a decoder rejected
////   the resulting shape

import gleam/dynamic/decode
import gleam/int

pub type YamlError {
  ParseError(message: String, line: Int, column: Int)
  Unsupported(feature: String, line: Int, column: Int)
  DecodeError(errors: List(decode.DecodeError))
}

/// Format an error as a single human-readable line for logging or
/// display. Intentionally simple — consumers wanting structured output
/// should pattern-match on the variants themselves.
pub fn to_string(err: YamlError) -> String {
  case err {
    ParseError(message, line, column) ->
      "yaml parse error at line "
      <> int.to_string(line)
      <> ", column "
      <> int.to_string(column)
      <> ": "
      <> message
    Unsupported(feature, line, column) ->
      "yaml feature not supported at line "
      <> int.to_string(line)
      <> ", column "
      <> int.to_string(column)
      <> ": "
      <> feature
    DecodeError(_) -> "yaml decode error: could not extract requested shape"
  }
}
