//// YAML parser.
////
//// Consumes the `List(Line)` produced by the lexer and constructs a
//// `YamlNode` tree. Recursive descent with indent-column tracking for
//// block structure, and a token-level descent for flow collections.
////
//// Three families of blocks:
//// - Mappings (lines whose first tokens are `key: ...`)
//// - Sequences (lines whose first token is `-`)
//// - Single scalars (a single line containing one scalar token)
////
//// The interesting case is `- key: value` opening an inline mapping
//// inside a sequence item. The parser tracks the column where the
//// mapping's first key sits and treats subsequent lines at that column
//// as continuations of the same mapping until indent drops or a dash
//// reappears at the sequence's indent level.
////
//// Anchors are threaded explicitly as a state parameter (`Anchors`)
//// through every parser function. A fresh table is created at the
//// start of each document and accumulated as `&name` declarations are
//// encountered; alias lookups (`*name`) read from the table at the
//// site of use. Nothing escapes the parser.

import gleam/float
import gleam/int
import gleam/list
import yamleam/anchors.{type Anchors} as anchor_table
import yamleam/error.{type YamlError, ParseError}
import yamleam/node.{
  type YamlNode, YamlBool, YamlFloat, YamlInt, YamlList, YamlMap, YamlNull,
  YamlString,
}
import yamleam/position.{type Position}
import yamleam/scalar
import yamleam/token.{
  type Line, type Token, AliasMarker, AnchorMarker, Colon, Comma, Dash,
  DocumentEnd, DocumentStart, FlowMapEnd, FlowMapStart, FlowSeqEnd, FlowSeqStart,
  Line, PlainScalar, QuotedScalar, Token,
}

/// Top-level entry: parse a list of lexer lines into a single `YamlNode`
/// tree. If the source contains multiple documents (more than one
/// non-empty segment separated by `---`/`...`), returns a `ParseError`.
/// Use `parse_all` if you need every document in a stream.
pub fn parse(lines: List(Line)) -> Result(YamlNode, YamlError) {
  let segments = split_into_documents(lines)
  case segments {
    [] -> Ok(YamlNull)
    [first] -> parse_one_document(first)
    [first, second, ..] ->
      case parse_one_document(first) {
        Error(e) -> Error(e)
        Ok(_) -> {
          let #(line, column) = segment_start_position(second)
          Error(ParseError(
            message: "multiple YAML documents found; use parse_all or parse_documents_raw for streams",
            line: line,
            column: column,
          ))
        }
      }
  }
}

/// Parse all documents in a YAML stream, splitting on `---` / `...`
/// markers. Returns one `YamlNode` per non-empty document. Empty
/// documents (between consecutive markers) are skipped.
pub fn parse_all(lines: List(Line)) -> Result(List(YamlNode), YamlError) {
  let segments = split_into_documents(lines)
  parse_segments(segments, [])
}

fn parse_segments(
  segments: List(List(Line)),
  acc: List(YamlNode),
) -> Result(List(YamlNode), YamlError) {
  case segments {
    [] -> Ok(list.reverse(acc))
    [seg, ..rest] ->
      case parse_one_document(seg) {
        Error(e) -> Error(e)
        Ok(node) -> parse_segments(rest, [node, ..acc])
      }
  }
}

fn parse_one_document(lines: List(Line)) -> Result(YamlNode, YamlError) {
  // Anchors are document-scoped per YAML 1.2 §6.9. A fresh table at
  // the start of each document means anchors from earlier documents
  // can't leak into later ones.
  let anchors = anchor_table.new()
  case lines {
    [] -> Ok(YamlNull)
    _ ->
      case parse_block(lines, 1, anchors) {
        Error(e) -> Error(e)
        Ok(#(node, [], _)) -> Ok(node)
        Ok(#(_node, [Line(line_number: ln, indent: col, ..), ..], _)) ->
          Error(ParseError(
            message: "unexpected content after document, indent "
              <> int.to_string(col),
            line: ln,
            column: col,
          ))
      }
  }
}

/// Split a flat list of lines into per-document segments using
/// `DocumentStart` (`---`) and `DocumentEnd` (`...`) markers as
/// separators. Empty segments (e.g. consecutive markers) are dropped.
fn split_into_documents(lines: List(Line)) -> List(List(Line)) {
  do_split_documents(lines, [], [])
}

fn do_split_documents(
  remaining: List(Line),
  current: List(Line),
  acc: List(List(Line)),
) -> List(List(Line)) {
  case remaining {
    [] -> finalize_segments(current, acc)
    [line, ..rest] -> {
      case is_document_marker(line) {
        True -> {
          // End the current segment, start a new one
          let acc2 = case list.reverse(current) {
            [] -> acc
            seg -> [seg, ..acc]
          }
          do_split_documents(rest, [], acc2)
        }
        False -> do_split_documents(rest, [line, ..current], acc)
      }
    }
  }
}

fn finalize_segments(
  current: List(Line),
  acc: List(List(Line)),
) -> List(List(Line)) {
  let acc2 = case list.reverse(current) {
    [] -> acc
    seg -> [seg, ..acc]
  }
  list.reverse(acc2)
}

fn segment_start_position(segment: List(Line)) -> #(Int, Int) {
  case segment {
    [Line(line_number: line, indent: indent, ..), ..] -> #(line, indent)
    [] -> #(1, 1)
  }
}

fn is_document_marker(line: Line) -> Bool {
  case line.tokens {
    [Token(kind: DocumentStart, ..)] -> True
    [Token(kind: DocumentEnd, ..)] -> True
    _ -> False
  }
}

// ── Block dispatch ──────────────────────────────────────────────────────────

/// Parse a block. The first line must be at column ≥ `min_indent`. The
/// block's actual indent is determined by the first line's column.
fn parse_block(
  lines: List(Line),
  min_indent: Int,
  anchors: Anchors,
) -> Result(#(YamlNode, List(Line), Anchors), YamlError) {
  case lines {
    [] -> Ok(#(YamlNull, [], anchors))
    [first, ..] ->
      case first.indent < min_indent {
        True -> Ok(#(YamlNull, lines, anchors))
        False -> dispatch_block(lines, first, anchors)
      }
  }
}

/// Parse the nested value of a mapping entry whose key sits at column
/// `key_indent` and has nothing after its `:`. The value is a block
/// indented past the key, or a compact block sequence whose dashes sit at
/// the key's own column (YAML 1.2 §8.2.1), as in
///
///     steps:
///     - run: make
fn parse_entry_value(
  lines: List(Line),
  key_indent: Int,
  anchors: Anchors,
) -> Result(#(YamlNode, List(Line), Anchors), YamlError) {
  case lines {
    [Line(indent: indent, tokens: [Token(kind: Dash, ..), ..], ..), ..]
      if indent == key_indent
    -> parse_sequence(lines, key_indent, anchors)
    _ -> parse_block(lines, key_indent + 1, anchors)
  }
}

fn dispatch_block(
  lines: List(Line),
  first: Line,
  anchors: Anchors,
) -> Result(#(YamlNode, List(Line), Anchors), YamlError) {
  let block_indent = first.indent
  case first.tokens {
    [] ->
      Error(ParseError(
        message: "internal: empty token line",
        line: first.line_number,
        column: block_indent,
      ))
    [Token(kind: Dash, ..), ..] -> parse_sequence(lines, block_indent, anchors)
    [Token(kind: PlainScalar(_), ..), Token(kind: Colon, ..), ..] ->
      parse_mapping(lines, block_indent, anchors)
    [Token(kind: QuotedScalar(_), ..), Token(kind: Colon, ..), ..] ->
      parse_mapping(lines, block_indent, anchors)
    // A single-line flow collection as the top-level value of a block
    // (e.g., a document that is just `[1, 2, 3]`).
    [Token(kind: FlowSeqStart, ..), ..] | [Token(kind: FlowMapStart, ..), ..] ->
      case parse_flow_value(first.tokens, first.line_number, anchors) {
        Error(e) -> Error(e)
        Ok(#(node, [], anchors2)) -> {
          let rest = case lines {
            [_, ..r] -> r
            [] -> []
          }
          Ok(#(node, rest, anchors2))
        }
        Ok(#(_node, [trail, ..], _)) ->
          Error(ParseError(
            message: "unexpected tokens after flow collection",
            line: trail.position.line,
            column: trail.position.column,
          ))
      }
    [single] -> {
      let value = scalar_token_to_node(single)
      let rest = case lines {
        [_, ..r] -> r
        [] -> []
      }
      Ok(#(value, rest, anchors))
    }
    _ ->
      Error(ParseError(
        message: "unexpected token sequence; expected mapping entry, sequence item, or single scalar",
        line: first.line_number,
        column: block_indent,
      ))
  }
}

// ── Mapping parser ──────────────────────────────────────────────────────────

fn parse_mapping(
  lines: List(Line),
  indent: Int,
  anchors: Anchors,
) -> Result(#(YamlNode, List(Line), Anchors), YamlError) {
  do_parse_mapping(lines, indent, [], [], anchors)
}

/// `acc` carries every entry in the mapping (both explicit and merged).
/// `explicit_keys` carries only the keys that came from explicit
/// assignment (not from a `<<:` merge). The duplicate-key check applies
/// to `explicit_keys` only — merged entries may be silently overridden
/// by later explicit assignments per YAML merge semantics.
fn do_parse_mapping(
  lines: List(Line),
  indent: Int,
  acc: List(#(String, YamlNode)),
  explicit_keys: List(String),
  anchors: Anchors,
) -> Result(#(YamlNode, List(Line), Anchors), YamlError) {
  case lines {
    [] -> Ok(#(YamlMap(list.reverse(acc)), [], anchors))
    [first, ..rest] ->
      case first.indent == indent && is_mapping_entry(first.tokens) {
        False -> Ok(#(YamlMap(list.reverse(acc)), lines, anchors))
        True ->
          case extract_mapping_entry(first) {
            Error(e) -> Error(e)
            Ok(#(key, value_tokens)) -> {
              let dup_check = case key {
                "<<" -> Ok(Nil)
                _ -> explicit_duplicate_error(key, explicit_keys, first)
              }
              case dup_check {
                Error(e) -> Error(e)
                Ok(_) ->
                  consume_mapping_value(
                    key,
                    value_tokens,
                    first,
                    rest,
                    indent,
                    acc,
                    explicit_keys,
                    anchors,
                  )
              }
            }
          }
      }
  }
}

/// YAML 1.2 §3.2.2.1 requires mapping keys to be unique. We enforce this
/// for explicit entries only — merged entries (from `<<:`) can be silently
/// overridden by later explicit assignments per YAML merge semantics.
fn explicit_duplicate_error(
  key: String,
  explicit_keys: List(String),
  line: Line,
) -> Result(Nil, YamlError) {
  case list.contains(explicit_keys, key) {
    True ->
      Error(ParseError(
        message: "duplicate mapping key '" <> key <> "'",
        line: line.line_number,
        column: line.indent,
      ))
    False -> Ok(Nil)
  }
}

/// Upsert a key/value into the accumulator. If the key already exists
/// (from a previous merge), the value is replaced in place — preserving
/// the original entry's position. If the key is new, the entry is
/// prepended (acc is reverse-built; the prepend becomes "appended" after
/// the final list.reverse).
fn upsert_key(
  acc: List(#(String, YamlNode)),
  key: String,
  value: YamlNode,
) -> List(#(String, YamlNode)) {
  case list.key_find(acc, key) {
    Ok(_) ->
      list.map(acc, fn(pair) {
        case pair.0 == key {
          True -> #(key, value)
          False -> pair
        }
      })
    Error(_) -> [#(key, value), ..acc]
  }
}

fn consume_mapping_value(
  key: String,
  value_tokens: List(Token),
  first: Line,
  rest: List(Line),
  indent: Int,
  acc: List(#(String, YamlNode)),
  explicit_keys: List(String),
  anchors: Anchors,
) -> Result(#(YamlNode, List(Line), Anchors), YamlError) {
  case value_tokens {
    [] -> {
      // Nested value comes from subsequent indented lines
      case parse_entry_value(rest, indent, anchors) {
        Error(e) -> Error(e)
        Ok(#(value, after, anchors2)) ->
          add_mapping_entry(
            key,
            value,
            first,
            after,
            indent,
            acc,
            explicit_keys,
            anchors2,
          )
      }
    }
    // Anchor sitting at the end of the line (before a nested block value):
    //   key: &name
    //     nested: value
    [Token(kind: AnchorMarker(name), ..)] -> {
      case parse_entry_value(rest, indent, anchors) {
        Error(e) -> Error(e)
        Ok(#(value, after, anchors2)) -> {
          let anchors3 = anchor_table.set(anchors2, name, value)
          add_mapping_entry(
            key,
            value,
            first,
            after,
            indent,
            acc,
            explicit_keys,
            anchors3,
          )
        }
      }
    }
    _ -> {
      case inline_value_to_node(value_tokens, first.line_number, anchors) {
        Error(e) -> Error(e)
        Ok(#(value, anchors2)) ->
          add_mapping_entry(
            key,
            value,
            first,
            rest,
            indent,
            acc,
            explicit_keys,
            anchors2,
          )
      }
    }
  }
}

/// Add an entry to a mapping accumulator, with special handling for the
/// merge key `<<`. When the key is `<<`, the value must be a `YamlMap`
/// (typically obtained via an alias `<<: *base`) or a list of mappings;
/// its entries are merged into the accumulator. Existing entries take
/// precedence per YAML merge-key semantics.
///
/// For explicit (non-merge) keys: if the key already exists in `acc`
/// (because a previous merge added it), it's removed and replaced.
fn add_mapping_entry(
  key: String,
  value: YamlNode,
  entry_line: Line,
  rest: List(Line),
  indent: Int,
  acc: List(#(String, YamlNode)),
  explicit_keys: List(String),
  anchors: Anchors,
) -> Result(#(YamlNode, List(Line), Anchors), YamlError) {
  case key {
    "<<" -> {
      case merge_into_acc(value, acc) {
        Ok(merged) ->
          do_parse_mapping(rest, indent, merged, explicit_keys, anchors)
        Error(msg) -> Error(merge_key_error(msg, entry_line))
      }
    }
    _ -> {
      // Upsert: if the key exists from a merge, replace its value in
      // place; otherwise prepend a new entry.
      do_parse_mapping(
        rest,
        indent,
        upsert_key(acc, key, value),
        [key, ..explicit_keys],
        anchors,
      )
    }
  }
}

/// Merge a referenced mapping (or list of mappings) into the current
/// accumulator. Existing keys win over merged keys per YAML 1.1 merge
/// semantics. Returns Error(message) if the value isn't a mapping or
/// a list of mappings.
fn merge_into_acc(
  value: YamlNode,
  acc: List(#(String, YamlNode)),
) -> Result(List(#(String, YamlNode)), String) {
  case value {
    YamlMap(pairs) -> Ok(merge_pairs_into_acc(pairs, acc))
    YamlList(items) -> merge_list_into_acc(items, acc)
    _ -> Error("merge key '<<' value must be a mapping or list of mappings")
  }
}

fn merge_key_error(message: String, line: Line) -> YamlError {
  ParseError(message: message, line: line.line_number, column: line.indent)
}

fn merge_list_into_acc(
  items: List(YamlNode),
  acc: List(#(String, YamlNode)),
) -> Result(List(#(String, YamlNode)), String) {
  case items {
    [] -> Ok(acc)
    [item, ..rest] ->
      case item {
        YamlMap(pairs) -> {
          let next = merge_pairs_into_acc(pairs, acc)
          merge_list_into_acc(rest, next)
        }
        _ -> Error("merge key '<<' list must contain only mappings")
      }
  }
}

fn merge_pairs_into_acc(
  pairs: List(#(String, YamlNode)),
  acc: List(#(String, YamlNode)),
) -> List(#(String, YamlNode)) {
  // Existing keys in `acc` take precedence over `pairs`. We append
  // pairs whose keys are NOT already present.
  case pairs {
    [] -> acc
    [#(k, v), ..rest] ->
      case list.key_find(acc, k) {
        Ok(_) -> merge_pairs_into_acc(rest, acc)
        Error(_) -> merge_pairs_into_acc(rest, [#(k, v), ..acc])
      }
  }
}

fn extract_mapping_entry(
  line: Line,
) -> Result(#(String, List(Token)), YamlError) {
  case line.tokens {
    [Token(kind: PlainScalar(k), ..), Token(kind: Colon, ..), ..rest] ->
      Ok(#(k, rest))
    [Token(kind: QuotedScalar(k), ..), Token(kind: Colon, ..), ..rest] ->
      Ok(#(k, rest))
    _ ->
      Error(ParseError(
        message: "expected mapping entry of the form 'key: value'",
        line: line.line_number,
        column: line.indent,
      ))
  }
}

fn is_mapping_entry(tokens: List(Token)) -> Bool {
  case tokens {
    [Token(kind: PlainScalar(_), ..), Token(kind: Colon, ..), ..] -> True
    [Token(kind: QuotedScalar(_), ..), Token(kind: Colon, ..), ..] -> True
    _ -> False
  }
}

fn inline_value_to_node(
  tokens: List(Token),
  line_num: Int,
  anchors: Anchors,
) -> Result(#(YamlNode, Anchors), YamlError) {
  case tokens {
    [] -> Ok(#(YamlNull, anchors))

    // Anchor before an inline value: consume the marker, parse the rest,
    // register the result, return it.
    [Token(kind: AnchorMarker(name), ..), ..rest] ->
      case inline_value_to_node(rest, line_num, anchors) {
        Error(e) -> Error(e)
        Ok(#(value, anchors2)) -> {
          let anchors3 = anchor_table.set(anchors2, name, value)
          Ok(#(value, anchors3))
        }
      }

    // Alias as the entire value: look up and substitute.
    [Token(kind: AliasMarker(name), position: pos)] ->
      case anchor_table.get(anchors, name) {
        Ok(value) -> Ok(#(value, anchors))
        Error(_) ->
          Error(ParseError(
            message: "unknown alias '*" <> name <> "'",
            line: pos.line,
            column: pos.column,
          ))
      }

    [single] -> Ok(#(scalar_token_to_node(single), anchors))

    [first, ..] ->
      // Flow collection as an inline value (e.g., `key: [1, 2, 3]`).
      // Delegate to the flow parser, then ensure there are no trailing
      // tokens after the close bracket/brace.
      case first.kind {
        FlowSeqStart | FlowMapStart ->
          case parse_flow_value(tokens, line_num, anchors) {
            Error(e) -> Error(e)
            Ok(#(node, [], anchors2)) -> Ok(#(node, anchors2))
            Ok(#(_node, [trail, ..], _)) ->
              Error(ParseError(
                message: "unexpected tokens after flow collection",
                line: trail.position.line,
                column: trail.position.column,
              ))
          }
        _ ->
          Error(ParseError(
            message: "value contains multiple tokens; quote the value if it includes ':' followed by space",
            line: line_num,
            column: 1,
          ))
      }
  }
}

// ── Flow-style parsing ──────────────────────────────────────────────────────
// Consumes tokens starting with a flow opener (`[` or `{`) and produces
// a `YamlNode` plus the remaining tokens. Recursive — supports nested
// flow collections.

fn parse_flow_value(
  tokens: List(Token),
  line_num: Int,
  anchors: Anchors,
) -> Result(#(YamlNode, List(Token), Anchors), YamlError) {
  case tokens {
    [] ->
      Error(ParseError(
        message: "expected flow value",
        line: line_num,
        column: 1,
      ))
    [first, ..rest] ->
      case first.kind {
        FlowSeqStart -> parse_flow_seq(rest, first.position.line, [], anchors)
        FlowMapStart -> parse_flow_map(rest, first.position.line, [], anchors)
        PlainScalar(_) | QuotedScalar(_) ->
          Ok(#(scalar_token_to_node(first), rest, anchors))
        AnchorMarker(name) ->
          // Anchor before a flow value: parse the rest, register, return.
          case parse_flow_value(rest, line_num, anchors) {
            Error(e) -> Error(e)
            Ok(#(value, after, anchors2)) -> {
              let anchors3 = anchor_table.set(anchors2, name, value)
              Ok(#(value, after, anchors3))
            }
          }
        AliasMarker(name) ->
          case anchor_table.get(anchors, name) {
            Ok(value) -> Ok(#(value, rest, anchors))
            Error(_) ->
              Error(ParseError(
                message: "unknown alias '*" <> name <> "'",
                line: first.position.line,
                column: first.position.column,
              ))
          }
        _ ->
          Error(ParseError(
            message: "unexpected token in flow value",
            line: first.position.line,
            column: first.position.column,
          ))
      }
  }
}

fn parse_flow_seq(
  tokens: List(Token),
  line_num: Int,
  acc: List(YamlNode),
  anchors: Anchors,
) -> Result(#(YamlNode, List(Token), Anchors), YamlError) {
  case tokens {
    [] ->
      Error(ParseError(
        message: "unterminated flow sequence: expected ']'",
        line: line_num,
        column: 1,
      ))
    [first, ..rest] ->
      case first.kind {
        FlowSeqEnd -> Ok(#(YamlList(list.reverse(acc)), rest, anchors))
        // Consecutive commas or leading comma — skip (permissive)
        Comma -> parse_flow_seq(rest, line_num, acc, anchors)
        _ ->
          case parse_flow_value(tokens, line_num, anchors) {
            Error(e) -> Error(e)
            Ok(#(value, after, anchors2)) ->
              // Check for implicit mapping: `key: value` inside flow sequence
              // YAML 1.2 allows `[key: value, ...]` as shorthand for `[{key: value}, ...]`
              case after {
                [colon_tok, ..after_colon] if colon_tok.kind == Colon -> {
                  case scalar_flow_key_to_string(value, colon_tok.position.line, colon_tok.position.column) {
                    Error(e) -> Error(e)
                    Ok(key_str) ->
                      case parse_flow_value(after_colon, line_num, anchors2) {
                        Error(e) -> Error(e)
                        Ok(#(map_value, after_value, anchors3)) -> {
                          let map_node = YamlMap([#(key_str, map_value)])
                          parse_flow_seq(after_value, line_num, [map_node, ..acc], anchors3)
                        }
                      }
                  }
                }
                _ -> parse_flow_seq(after, line_num, [value, ..acc], anchors2)
              }
          }
      }
  }
}

fn parse_flow_map(
  tokens: List(Token),
  line_num: Int,
  acc: List(#(String, YamlNode)),
  anchors: Anchors,
) -> Result(#(YamlNode, List(Token), Anchors), YamlError) {
  case tokens {
    [] ->
      Error(ParseError(
        message: "unterminated flow mapping: expected '}'",
        line: line_num,
        column: 1,
      ))
    [first, ..rest] ->
      case first.kind {
        FlowMapEnd -> Ok(#(YamlMap(list.reverse(acc)), rest, anchors))
        Comma -> parse_flow_map(rest, line_num, acc, anchors)
        PlainScalar(k) ->
          parse_flow_map_entry(k, first.position, rest, line_num, acc, anchors)
        QuotedScalar(k) ->
          parse_flow_map_entry(k, first.position, rest, line_num, acc, anchors)
        _ ->
          Error(ParseError(
            message: "expected key in flow mapping",
            line: first.position.line,
            column: first.position.column,
          ))
      }
  }
}

fn parse_flow_map_entry(
  key: String,
  key_position: Position,
  after_key: List(Token),
  line_num: Int,
  acc: List(#(String, YamlNode)),
  anchors: Anchors,
) -> Result(#(YamlNode, List(Token), Anchors), YamlError) {
  case after_key {
    [Token(kind: Colon, ..), ..after_colon] ->
      case parse_flow_value(after_colon, line_num, anchors) {
        Error(e) -> Error(e)
        Ok(#(value, after_value, anchors2)) ->
          case list.key_find(acc, key) {
            Ok(_) ->
              Error(ParseError(
                message: "duplicate mapping key '" <> key <> "' in flow mapping",
                line: key_position.line,
                column: key_position.column,
              ))
            Error(_) ->
              parse_flow_map(
                after_value,
                line_num,
                [#(key, value), ..acc],
                anchors2,
              )
          }
      }
    _ ->
      Error(ParseError(
        message: "expected ':' after key '" <> key <> "' in flow mapping",
        line: key_position.line,
        column: key_position.column,
      ))
  }
}

// ── Sequence parser ─────────────────────────────────────────────────────────

fn parse_sequence(
  lines: List(Line),
  indent: Int,
  anchors: Anchors,
) -> Result(#(YamlNode, List(Line), Anchors), YamlError) {
  do_parse_sequence(lines, indent, [], anchors)
}

fn do_parse_sequence(
  lines: List(Line),
  indent: Int,
  acc: List(YamlNode),
  anchors: Anchors,
) -> Result(#(YamlNode, List(Line), Anchors), YamlError) {
  case lines {
    [] -> Ok(#(YamlList(list.reverse(acc)), [], anchors))
    [first, ..rest] ->
      case first.indent == indent && starts_with_dash(first.tokens) {
        False -> Ok(#(YamlList(list.reverse(acc)), lines, anchors))
        True ->
          case parse_sequence_item(first, rest, indent, anchors) {
            Error(e) -> Error(e)
            Ok(#(item, after, anchors2)) ->
              do_parse_sequence(after, indent, [item, ..acc], anchors2)
          }
      }
  }
}

fn starts_with_dash(tokens: List(Token)) -> Bool {
  case tokens {
    [Token(kind: Dash, ..), ..] -> True
    _ -> False
  }
}

fn parse_sequence_item(
  dash_line: Line,
  rest: List(Line),
  seq_indent: Int,
  anchors: Anchors,
) -> Result(#(YamlNode, List(Line), Anchors), YamlError) {
  // Drop the leading Dash; what's left after it is the inline content
  let content = drop_first(dash_line.tokens)

  case content {
    // Bare dash — value comes from subsequent lines indented past the dash
    [] -> parse_block(rest, seq_indent + 1, anchors)

    // Anchor on a dash line (e.g., `- &name value` or `- &name` then nested)
    [Token(kind: AnchorMarker(name), ..), ..rest_content] ->
      parse_sequence_item_after_anchor(
        name,
        rest_content,
        dash_line,
        rest,
        seq_indent,
        anchors,
      )

    // Alias as a complete item: `- *name`
    [Token(kind: AliasMarker(name), position: pos)] ->
      case anchor_table.get(anchors, name) {
        Ok(value) -> Ok(#(value, rest, anchors))
        Error(_) ->
          Error(ParseError(
            message: "unknown alias '*" <> name <> "'",
            line: pos.line,
            column: pos.column,
          ))
      }

    // Flow collection as a sequence item: `- [1, 2, 3]` or `- {a: 1}`
    [Token(kind: FlowSeqStart, ..), ..] | [Token(kind: FlowMapStart, ..), ..] ->
      case parse_flow_value(content, dash_line.line_number, anchors) {
        Error(e) -> Error(e)
        Ok(#(node, [], anchors2)) -> Ok(#(node, rest, anchors2))
        Ok(#(_node, [trail, ..], _)) ->
          Error(ParseError(
            message: "unexpected tokens after flow collection",
            line: trail.position.line,
            column: trail.position.column,
          ))
      }

    // Single scalar item: `- value`
    [single] ->
      case single.kind {
        PlainScalar(_) | QuotedScalar(_) ->
          Ok(#(scalar_token_to_node(single), rest, anchors))
        _ ->
          Error(ParseError(
            message: "unexpected token after '-'",
            line: dash_line.line_number,
            column: dash_line.indent,
          ))
      }

    // Inline mapping start: `- key: value...` or `- key:`
    [first_tok, Token(kind: Colon, ..), ..value_tokens] -> {
      case first_tok.kind {
        PlainScalar(k) ->
          parse_inline_mapping_item(k, first_tok, value_tokens, rest, anchors)
        QuotedScalar(k) ->
          parse_inline_mapping_item(k, first_tok, value_tokens, rest, anchors)
        _ ->
          Error(ParseError(
            message: "expected key after '-'",
            line: dash_line.line_number,
            column: dash_line.indent,
          ))
      }
    }

    _ ->
      Error(ParseError(
        message: "unexpected token sequence after '-'",
        line: dash_line.line_number,
        column: dash_line.indent,
      ))
  }
}

/// Handle `- &name <value>` and `- &name` followed by a nested block.
fn parse_sequence_item_after_anchor(
  name: String,
  rest_content: List(Token),
  dash_line: Line,
  rest_lines: List(Line),
  seq_indent: Int,
  anchors: Anchors,
) -> Result(#(YamlNode, List(Line), Anchors), YamlError) {
  case rest_content {
    [] -> {
      // `- &name` followed by a nested block on subsequent lines
      case parse_block(rest_lines, seq_indent + 1, anchors) {
        Error(e) -> Error(e)
        Ok(#(value, after, anchors2)) -> {
          let anchors3 = anchor_table.set(anchors2, name, value)
          Ok(#(value, after, anchors3))
        }
      }
    }
    _ -> {
      // Inline value following the anchor on the dash line.
      // Use inline_value_to_node which itself handles flow values, scalars,
      // and nested anchors/aliases.
      case inline_value_to_node(rest_content, dash_line.line_number, anchors) {
        Error(e) -> Error(e)
        Ok(#(value, anchors2)) -> {
          let anchors3 = anchor_table.set(anchors2, name, value)
          Ok(#(value, rest_lines, anchors3))
        }
      }
    }
  }
}

/// `- key: value` (or `- key:` with nested value) opens a mapping whose
/// effective indent column is the column where the first key sits. This
/// function builds the first entry, then continues consuming subsequent
/// mapping entries from `rest_lines` at the same effective indent.
fn parse_inline_mapping_item(
  key: String,
  first_tok: Token,
  value_tokens: List(Token),
  rest_lines: List(Line),
  anchors: Anchors,
) -> Result(#(YamlNode, List(Line), Anchors), YamlError) {
  let mapping_indent = first_tok.position.column

  case value_tokens {
    [] ->
      // Nested value for this first key — read it from rest_lines
      case parse_entry_value(rest_lines, mapping_indent, anchors) {
        Error(e) -> Error(e)
        Ok(#(value, after_value, anchors2)) ->
          start_inline_mapping(
            key,
            value,
            Line(
              indent: mapping_indent,
              line_number: first_tok.position.line,
              tokens: [],
            ),
            after_value,
            mapping_indent,
            anchors2,
          )
      }
    _ ->
      case
        inline_value_to_node(value_tokens, first_tok.position.line, anchors)
      {
        Error(e) -> Error(e)
        Ok(#(value, anchors2)) ->
          start_inline_mapping(
            key,
            value,
            Line(
              indent: mapping_indent,
              line_number: first_tok.position.line,
              tokens: [],
            ),
            rest_lines,
            mapping_indent,
            anchors2,
          )
      }
  }
}

/// Bootstrap an inline mapping accumulator from the first key/value pair,
/// handling the merge-key special case.
fn start_inline_mapping(
  key: String,
  value: YamlNode,
  entry_line: Line,
  rest: List(Line),
  mapping_indent: Int,
  anchors: Anchors,
) -> Result(#(YamlNode, List(Line), Anchors), YamlError) {
  case key {
    "<<" -> {
      case merge_into_acc(value, []) {
        Ok(merged) ->
          continue_inline_mapping(merged, [], rest, mapping_indent, anchors)
        Error(msg) -> Error(merge_key_error(msg, entry_line))
      }
    }
    _ ->
      continue_inline_mapping(
        [#(key, value)],
        [key],
        rest,
        mapping_indent,
        anchors,
      )
  }
}

/// Continue building an inline mapping started by a `- key: value` line.
/// Stops as soon as a line breaks the indent contract (column ≠
/// `mapping_indent` or not shaped like a mapping entry).
fn continue_inline_mapping(
  acc_reversed: List(#(String, YamlNode)),
  explicit_keys: List(String),
  lines: List(Line),
  mapping_indent: Int,
  anchors: Anchors,
) -> Result(#(YamlNode, List(Line), Anchors), YamlError) {
  case lines {
    [] -> Ok(#(YamlMap(list.reverse(acc_reversed)), [], anchors))
    [first, ..rest] ->
      case first.indent == mapping_indent && is_mapping_entry(first.tokens) {
        False -> Ok(#(YamlMap(list.reverse(acc_reversed)), lines, anchors))
        True ->
          case extract_mapping_entry(first) {
            Error(e) -> Error(e)
            Ok(#(key, value_tokens)) -> {
              let dup_check = case key {
                "<<" -> Ok(Nil)
                _ -> explicit_duplicate_error(key, explicit_keys, first)
              }
              case dup_check {
                Error(e) -> Error(e)
                Ok(_) ->
                  consume_inline_mapping_value(
                    key,
                    value_tokens,
                    first,
                    rest,
                    mapping_indent,
                    acc_reversed,
                    explicit_keys,
                    anchors,
                  )
              }
            }
          }
      }
  }
}

/// Add a value (possibly merge-keyed) to an inline mapping accumulator.
fn consume_inline_mapping_value(
  key: String,
  value_tokens: List(Token),
  first: Line,
  rest: List(Line),
  mapping_indent: Int,
  acc_reversed: List(#(String, YamlNode)),
  explicit_keys: List(String),
  anchors: Anchors,
) -> Result(#(YamlNode, List(Line), Anchors), YamlError) {
  case value_tokens {
    [] -> {
      case parse_entry_value(rest, mapping_indent, anchors) {
        Error(e) -> Error(e)
        Ok(#(value, after, anchors2)) ->
          add_inline_mapping_entry(
            key,
            value,
            first,
            after,
            mapping_indent,
            acc_reversed,
            explicit_keys,
            anchors2,
          )
      }
    }
    [Token(kind: AnchorMarker(name), ..)] -> {
      case parse_entry_value(rest, mapping_indent, anchors) {
        Error(e) -> Error(e)
        Ok(#(value, after, anchors2)) -> {
          let anchors3 = anchor_table.set(anchors2, name, value)
          add_inline_mapping_entry(
            key,
            value,
            first,
            after,
            mapping_indent,
            acc_reversed,
            explicit_keys,
            anchors3,
          )
        }
      }
    }
    _ -> {
      case inline_value_to_node(value_tokens, first.line_number, anchors) {
        Error(e) -> Error(e)
        Ok(#(value, anchors2)) ->
          add_inline_mapping_entry(
            key,
            value,
            first,
            rest,
            mapping_indent,
            acc_reversed,
            explicit_keys,
            anchors2,
          )
      }
    }
  }
}

fn add_inline_mapping_entry(
  key: String,
  value: YamlNode,
  entry_line: Line,
  rest: List(Line),
  mapping_indent: Int,
  acc_reversed: List(#(String, YamlNode)),
  explicit_keys: List(String),
  anchors: Anchors,
) -> Result(#(YamlNode, List(Line), Anchors), YamlError) {
  case key {
    "<<" -> {
      case merge_into_acc(value, acc_reversed) {
        Ok(merged) ->
          continue_inline_mapping(
            merged,
            explicit_keys,
            rest,
            mapping_indent,
            anchors,
          )
        Error(msg) -> Error(merge_key_error(msg, entry_line))
      }
    }
    _ ->
      continue_inline_mapping(
        upsert_key(acc_reversed, key, value),
        [key, ..explicit_keys],
        rest,
        mapping_indent,
        anchors,
      )
  }
}

// ── Helpers ─────────────────────────────────────────────────────────────────

fn scalar_token_to_node(t: Token) -> YamlNode {
  case t.kind {
    PlainScalar(text) -> scalar.resolve(text)
    QuotedScalar(text) -> YamlString(text)
    _ -> YamlNull
  }
}

/// Convert a scalar YamlNode into a mapping key string for implicit
/// flow-sequence mappings (`[key: value]`). Non-scalar keys are rejected
/// as complex keys, which are not supported.
fn scalar_flow_key_to_string(
  node: YamlNode,
  line: Int,
  column: Int,
) -> Result(String, YamlError) {
  case node {
    YamlString(s) -> Ok(s)
    YamlInt(i) -> Ok(int.to_string(i))
    YamlFloat(f) -> Ok(float.to_string(f))
    YamlBool(True) -> Ok("true")
    YamlBool(False) -> Ok("false")
    YamlNull -> Ok("null")
    _ ->
      Error(ParseError(
        message: "complex keys are not supported in flow sequence pairs",
        line: line,
        column: column,
      ))
  }
}

fn drop_first(items: List(a)) -> List(a) {
  case items {
    [] -> []
    [_, ..rest] -> rest
  }
}
