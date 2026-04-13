//// yamleam — a pure-Gleam YAML parser.
////
//// Public API. Implementation lives under `src/yamleam/`. See README.md
//// and ROADMAP.md for the supported subset, the planned coverage, and
//// the design philosophy.

import gleam/dynamic/decode
import gleam/list
import yamleam/decoder
import yamleam/error
import yamleam/lexer
import yamleam/node
import yamleam/parser

// ── Re-exports ──────────────────────────────────────────────────────────────

pub type YamlNode =
  node.YamlNode

pub type YamlError =
  error.YamlError

// Convenience aliases so callers can pattern-match using short names.

pub const yaml_null = node.YamlNull

pub fn yaml_bool(b: Bool) -> YamlNode {
  node.YamlBool(b)
}

pub fn yaml_int(i: Int) -> YamlNode {
  node.YamlInt(i)
}

pub fn yaml_float(f: Float) -> YamlNode {
  node.YamlFloat(f)
}

pub fn yaml_string(s: String) -> YamlNode {
  node.YamlString(s)
}

pub fn yaml_list(items: List(YamlNode)) -> YamlNode {
  node.YamlList(items)
}

pub fn yaml_map(pairs: List(#(String, YamlNode))) -> YamlNode {
  node.YamlMap(pairs)
}

// ── Public API ──────────────────────────────────────────────────────────────

/// Parse a YAML source string into a typed `YamlNode` tree.
///
/// Returns a `ParseError` for invalid YAML or an `Unsupported` error for
/// features yamleam does not yet implement. Multi-document streams are
/// rejected; use `parse_documents_raw` for those.
pub fn parse_raw(source: String) -> Result(YamlNode, YamlError) {
  case lexer.tokenize(source) {
    Error(e) -> Error(e)
    Ok(lines) -> parser.parse(lines)
  }
}

/// Parse a YAML source string and run a decoder on the resulting tree.
///
/// The decoder is a standard `gleam/dynamic/decode.Decoder(a)`, the same
/// type used by `gleam_json.parse`. Decoders written for JSON sources
/// can be reused unchanged against YAML sources. Multi-document streams
/// are rejected; use `parse_documents` for those.
pub fn parse(source: String, decoder: decode.Decoder(a)) -> Result(a, YamlError) {
  case parse_raw(source) {
    Error(e) -> Error(e)
    Ok(tree) -> {
      let dyn = decoder.to_dynamic(tree)
      case decode.run(dyn, decoder) {
        Ok(value) -> Ok(value)
        Error(errors) -> Error(error.DecodeError(errors))
      }
    }
  }
}

// ── Multi-document streams ──────────────────────────────────────────────────

/// Parse a YAML stream containing one or more documents into a list of
/// `YamlNode` trees. Documents are separated by `---` (start) or `...`
/// (end) markers as defined in YAML 1.2 §9.
///
/// A stream with no markers and a single document returns `[node]`.
/// An empty stream returns `[]`.
///
/// Use `parse_documents` if you want each document run through a decoder.
pub fn parse_documents_raw(source: String) -> Result(List(YamlNode), YamlError) {
  case lexer.tokenize(source) {
    Error(e) -> Error(e)
    Ok(lines) -> parser.parse_all(lines)
  }
}

/// Parse a YAML stream containing one or more documents and run the
/// given decoder against each document. Returns a list of decoded values
/// in document order.
pub fn parse_documents(
  source: String,
  decoder: decode.Decoder(a),
) -> Result(List(a), YamlError) {
  case parse_documents_raw(source) {
    Error(e) -> Error(e)
    Ok(trees) -> decode_each(trees, decoder, [])
  }
}

fn decode_each(
  trees: List(YamlNode),
  decoder: decode.Decoder(a),
  acc: List(a),
) -> Result(List(a), YamlError) {
  case trees {
    [] -> Ok(list.reverse(acc))
    [tree, ..rest] -> {
      let dyn = decoder.to_dynamic(tree)
      case decode.run(dyn, decoder) {
        Error(errors) -> Error(error.DecodeError(errors))
        Ok(value) -> decode_each(rest, decoder, [value, ..acc])
      }
    }
  }
}
