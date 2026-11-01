//// Parse YAML with every number kept exactly as written.
////
//// `parse` and `parse_documents` read the same YAML as `yamleam.parse_raw`
//// and `yamleam.parse_documents_raw`, and return an `ExactNode` tree. A plain
//// scalar that `parse_raw` resolves to `YamlInt` or `YamlFloat` is an
//// `ExactNumber` holding its own text, so `0.0323`, `12.50` or a 30-digit
//// integer reach you without passing through a `Float`. Everything else is
//// the same: `01234`, `0x1F`, `.inf` and quoted `"1.5"` are strings in
//// both trees.
////
//// ```gleam
//// import yamleam/exact
//// import yamleam/node.{ExactMap, ExactNumber}
////
//// let assert Ok(ExactMap([#("rate", ExactNumber(text))])) =
////   exact.parse("rate: 0.0323")
//// // text == "0.0323"; hand it to your decimal library
//// ```
////
//// The text is the scalar as written, sign and exponent included (`+1.5e3`),
//// so a decimal parser decides for itself which forms it accepts.

import gleam/list
import yamleam/error.{type YamlError}
import yamleam/lexer
import yamleam/node.{
  type ExactNode, type YamlNode, ExactBool, ExactList, ExactMap, ExactNull,
  ExactNumber, ExactString, YamlBool, YamlList, YamlMap, YamlNull, YamlString,
}
import yamleam/parser
import yamleam/scalar

/// Parse a YAML source string into an `ExactNode` tree. Reads exactly one
/// document, and fails as `yamleam.parse_raw` does.
pub fn parse(source: String) -> Result(ExactNode, YamlError) {
  case lexer.tokenize(source) {
    Error(e) -> Error(e)
    Ok(lines) -> parser.parse(lines)
  }
}

/// Parse a YAML stream of one or more documents into `ExactNode` trees, as
/// `yamleam.parse_documents_raw` does.
pub fn parse_documents(source: String) -> Result(List(ExactNode), YamlError) {
  case lexer.tokenize(source) {
    Error(e) -> Error(e)
    Ok(lines) -> parser.parse_all(lines)
  }
}

/// The `YamlNode` tree for an `ExactNode` tree: each number resolves to
/// `YamlInt` or `YamlFloat`, as `yamleam.parse_raw` would have returned it.
pub fn to_yaml_node(node: ExactNode) -> YamlNode {
  case node {
    ExactNull -> YamlNull
    ExactBool(b) -> YamlBool(b)
    ExactNumber(text) -> scalar.resolve_number(text)
    ExactString(s) -> YamlString(s)
    ExactList(items) -> YamlList(list.map(items, to_yaml_node))
    ExactMap(pairs) ->
      YamlMap(
        list.map(pairs, fn(pair) {
          let #(key, value) = pair
          #(key, to_yaml_node(value))
        }),
      )
  }
}
