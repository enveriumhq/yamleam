//// YAML lexer — line-oriented.
////
//// Splits the source into lines, drops blank/comment-only lines, and
//// tokenizes each remaining line into a `Line(indent, line_number, tokens)`.
//// The parser consumes the resulting `List(Line)` using indent comparison.
////
//// Constructs that span several source lines become a single token:
//// - **Block scalars** (`|`, `>`, with `-`/`+` chomping). When the lexer
////   sees an opener at end-of-line position, it reads continuation lines
////   until indent returns to the parent level, then emits a
////   `QuotedScalar` token with folding and chomping applied.
//// - **Quoted strings**, single or double, that continue onto following
////   lines.
//// - **Plain scalars** that continue onto more-indented lines, folded
////   into one value.
////
//// Flow indicators (`[`, `]`, `{`, `}`, `,`) are tracked with a flow
//// depth so they only act as terminators inside flow context. Tabs in
//// indentation are rejected, and tags (`!`) return `Unsupported`.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import yamleam/error.{type YamlError, ParseError, Unsupported}
import yamleam/position.{type Position, Position}
import yamleam/token.{
  type Line, type Token, AliasMarker, AnchorMarker, Colon, Comma, Dash,
  DocumentEnd, DocumentStart, FlowMapEnd, FlowMapStart, FlowSeqEnd, FlowSeqStart,
  Line, PlainScalar, QuotedScalar, Token,
}

// ── Internal types ──────────────────────────────────────────────────────────

/// How a block scalar handles trailing newlines.
type BlockChomping {
  /// `|`/`>` (default) — keep exactly one trailing newline.
  Clip
  /// `|-`/`>-` — strip all trailing newlines.
  Strip
  /// `|+`/`>+` — preserve all trailing newlines as-is.
  Keep
}

/// Whether a block scalar joins content lines with `\n` (literal `|`)
/// or applies paragraph folding (`>`).
type BlockStyle {
  Literal
  Folded
}

/// State carried out of `tokenize_content` when a block scalar opener
/// (`|`, `>`, and chomping variants) is encountered. The caller is
/// responsible for reading the continuation lines and assembling the
/// final QuotedScalar.
type PendingBlock {
  PendingBlock(style: BlockStyle, chomping: BlockChomping, position: Position)
}

// ── Public entry ────────────────────────────────────────────────────────────

/// Tokenize a YAML source string into a list of logical lines.
pub fn tokenize(source: String) -> Result(List(Line), YamlError) {
  let raw_lines = string.split(normalize_source(source), on: "\n")
  do_tokenize_lines(raw_lines, 1, [])
}

/// Drop a leading byte order mark and normalize CRLF and CR line breaks
/// to LF (YAML 1.2 §5.2 and §5.4), so files saved on Windows read the
/// same as any other.
fn normalize_source(source: String) -> String {
  let without_bom = case source {
    "\u{FEFF}" <> rest -> rest
    _ -> source
  }
  without_bom
  |> string.replace(each: "\r\n", with: "\n")
  |> string.replace(each: "\r", with: "\n")
}

fn do_tokenize_lines(
  raw_lines: List(String),
  line_num: Int,
  acc: List(Line),
) -> Result(List(Line), YamlError) {
  case raw_lines {
    [] -> Ok(list.reverse(acc))
    [raw, ..rest] -> {
      case process_line(raw, line_num, rest) {
        Error(e) -> Error(e)
        Ok(#(produced, new_rest, extra_consumed)) ->
          do_tokenize_lines(
            new_rest,
            line_num + 1 + extra_consumed,
            prepend_all(produced, acc),
          )
      }
    }
  }
}

fn prepend_all(items: List(a), acc: List(a)) -> List(a) {
  case items {
    [] -> acc
    [h, ..t] -> prepend_all(t, [h, ..acc])
  }
}

/// Process a single raw line, possibly consuming additional raw lines if
/// the line contains a block scalar opener. Returns:
/// - `produced` — 0 or 1 `Line` values to add to the lexer output
/// - `new_rest` — the remaining raw lines after any block scalar consumption
/// - `extra_consumed` — how many lines from `rest_raw` were consumed (≥ 0)
fn process_line(
  raw: String,
  line_num: Int,
  rest_raw: List(String),
) -> Result(#(List(Line), List(String), Int), YamlError) {
  let graphemes = string.to_graphemes(raw)

  case validate_indent(graphemes, line_num) {
    Error(e) -> Error(e)
    Ok(#(indent_count, content_graphemes)) -> {
      case content_graphemes {
        [] -> Ok(#([], rest_raw, 0))
        ["#", ..] -> Ok(#([], rest_raw, 0))
        _ -> {
          let start_col = indent_count + 1
          // Document markers (`---`, `...`) must be at column 1 (no indent)
          // and must constitute the entire line content (modulo trailing
          // whitespace or comment).
          case indent_count, try_document_marker(content_graphemes, line_num) {
            0, Some(line) -> Ok(#([line], rest_raw, 0))
            _, _ ->
              tokenize_normal_line(
                content_graphemes,
                line_num,
                start_col,
                indent_count,
                rest_raw,
              )
          }
        }
      }
    }
  }
}

/// Recognize a `---` or `...` line. Returns `Some(line)` if matched,
/// `None` otherwise (caller falls through to normal tokenization).
fn try_document_marker(graphemes: List(String), line_num: Int) -> Option(Line) {
  case graphemes {
    ["-", "-", "-", ..rest] ->
      case is_only_whitespace_or_comment(rest) {
        True ->
          Some(
            Line(indent: 1, line_number: line_num, tokens: [
              Token(kind: DocumentStart, position: Position(line_num, 1)),
            ]),
          )
        False -> None
      }
    [".", ".", ".", ..rest] ->
      case is_only_whitespace_or_comment(rest) {
        True ->
          Some(
            Line(indent: 1, line_number: line_num, tokens: [
              Token(kind: DocumentEnd, position: Position(line_num, 1)),
            ]),
          )
        False -> None
      }
    _ -> None
  }
}

fn tokenize_normal_line(
  content_graphemes: List(String),
  line_num: Int,
  start_col: Int,
  indent_count: Int,
  rest_raw: List(String),
) -> Result(#(List(Line), List(String), Int), YamlError) {
  case tokenize_content_ml(
    content_graphemes,
    line_num,
    start_col,
    0,
    [],
    rest_raw,
    0,
  ) {
    Error(e) -> Error(e)
    Ok(#([], _, new_rest, extra)) -> Ok(#([], new_rest, extra))
    Ok(#(tokens, None, new_rest, extra)) -> {
      let line = Line(indent: start_col, line_number: line_num, tokens: tokens)
      Ok(#([line], new_rest, extra))
    }
    Ok(#(tokens_before, Some(pending), new_rest, extra)) -> {
      // Block scalar opener at end of this line. Read continuation
      // lines from new_rest, build the QuotedScalar token, append.
      let #(content, final_rest, block_consumed) =
        read_block_scalar(
          new_rest,
          indent_count,
          pending.style,
          pending.chomping,
        )
      let scalar_token =
        Token(kind: QuotedScalar(content), position: pending.position)
      let all_tokens = list_append(tokens_before, [scalar_token])
      let line =
        Line(indent: start_col, line_number: line_num, tokens: all_tokens)
      Ok(#([line], final_rest, extra + block_consumed))
    }
  }
}

fn list_append(a: List(t), b: List(t)) -> List(t) {
  list.append(a, b)
}

/// Walk leading whitespace, counting columns. Returns indent count + the
/// remaining graphemes after the indent. Errors if a tab is encountered
/// in the indent (yamleam forbids tab indentation).
fn validate_indent(
  graphemes: List(String),
  line_num: Int,
) -> Result(#(Int, List(String)), YamlError) {
  do_validate_indent(graphemes, line_num, 0)
}

fn do_validate_indent(
  graphemes: List(String),
  line_num: Int,
  count: Int,
) -> Result(#(Int, List(String)), YamlError) {
  case graphemes {
    [" ", ..rest] -> do_validate_indent(rest, line_num, count + 1)
    ["\t", ..] ->
      Error(ParseError(
        message: "tab character in indentation; yamleam requires spaces only",
        line: line_num,
        column: count + 1,
      ))
    other -> Ok(#(count, other))
  }
}

// ── Token-by-token tokenizer ────────────────────────────────────────────────

fn tokenize_content_ml(
  graphemes: List(String),
  line_num: Int,
  col: Int,
  flow_depth: Int,
  acc: List(Token),
  rest_raw: List(String),
  extra_consumed: Int,
) -> Result(#(List(Token), Option(PendingBlock), List(String), Int), YamlError) {
  case graphemes {
    [] -> end_of_line(line_num, flow_depth, acc, rest_raw, extra_consumed)

    // Whitespace between tokens
    [" ", ..rest] -> tokenize_content_ml(rest, line_num, col + 1, flow_depth, acc, rest_raw, extra_consumed)

    // Inline comment terminator
    ["#", ..] -> end_of_line(line_num, flow_depth, acc, rest_raw, extra_consumed)

    // Dash — sequence item marker (only if followed by space or EOL
    // and only in block context; inside flow, `-` is plain content)
    ["-", ..rest] ->
      case flow_depth == 0 && is_separator_followup(rest) {
        True -> {
          let tok = Token(kind: Dash, position: Position(line_num, col))
          tokenize_content_ml(rest, line_num, col + 1, flow_depth, [tok, ..acc], rest_raw, extra_consumed)
        }
        False ->
          read_plain_then_continue_ml(graphemes, line_num, col, flow_depth, acc, rest_raw, extra_consumed)
      }

    // Colon — mapping separator
    // Block context: must be followed by whitespace or EOL
    // Flow context: the same, or directly after a JSON-like node
    [":", ..rest] ->
      case is_separator_followup(rest) || follows_json_node(flow_depth, acc) {
        True -> {
          let tok = Token(kind: Colon, position: Position(line_num, col))
          tokenize_content_ml(rest, line_num, col + 1, flow_depth, [tok, ..acc], rest_raw, extra_consumed)
        }
        False ->
          Error(ParseError(
            message: "':' must be followed by whitespace or end of line",
            line: line_num,
            column: col,
          ))
      }

    // Single-quoted string
    ["'", ..rest] ->
      case
        read_single_quoted(
          rest,
          line_num,
          col + 1,
          [],
          [],
          rest_raw,
          extra_consumed,
        )
      {
        Error(e) -> Error(e)
        Ok(#(text, remaining, new_col, new_rest_raw, new_extra)) -> {
          let tok =
            Token(kind: QuotedScalar(text), position: Position(line_num, col))
          tokenize_content_ml(
            remaining,
            line_num,
            new_col,
            flow_depth,
            [tok, ..acc],
            new_rest_raw,
            new_extra,
          )
        }
      }

    // Double-quoted string (supports multi-line via rest_raw)
    ["\"", ..rest] ->
      case read_double_quoted_ml(rest, line_num, col + 1, [], [], rest_raw, extra_consumed) {
        Error(e) -> Error(e)
        Ok(#(text, remaining, new_col, new_rest_raw, new_extra)) -> {
          let tok =
            Token(kind: QuotedScalar(text), position: Position(line_num, col))
          tokenize_content_ml(remaining, line_num, new_col, flow_depth, [
            tok,
            ..acc
          ], new_rest_raw, new_extra)
        }
      }

    // Literal block scalar opener (block context only)
    ["|", ..rest] if flow_depth == 0 ->
      case parse_block_scalar_header(rest, line_num, col + 1) {
        Error(e) -> Error(e)
        Ok(chomping) ->
          Ok(#(
            list.reverse(acc),
            Some(PendingBlock(
              style: Literal,
              chomping: chomping,
              position: Position(line_num, col),
            )),
            rest_raw,
            extra_consumed,
          ))
      }

    // Folded block scalar opener (block context only)
    [">", ..rest] if flow_depth == 0 ->
      case parse_block_scalar_header(rest, line_num, col + 1) {
        Error(e) -> Error(e)
        Ok(chomping) ->
          Ok(#(
            list.reverse(acc),
            Some(PendingBlock(
              style: Folded,
              chomping: chomping,
              position: Position(line_num, col),
            )),
            rest_raw,
            extra_consumed,
          ))
      }

    // Flow-style sequence open
    ["[", ..rest] -> {
      let tok = Token(kind: FlowSeqStart, position: Position(line_num, col))
      tokenize_content_ml(rest, line_num, col + 1, flow_depth + 1, [tok, ..acc], rest_raw, extra_consumed)
    }

    // Flow-style sequence close
    ["]", ..rest] -> {
      let tok = Token(kind: FlowSeqEnd, position: Position(line_num, col))
      let new_depth = case flow_depth > 0 {
        True -> flow_depth - 1
        False -> 0
      }
      tokenize_content_ml(rest, line_num, col + 1, new_depth, [tok, ..acc], rest_raw, extra_consumed)
    }

    // Flow-style mapping open
    ["{", ..rest] -> {
      let tok = Token(kind: FlowMapStart, position: Position(line_num, col))
      tokenize_content_ml(rest, line_num, col + 1, flow_depth + 1, [tok, ..acc], rest_raw, extra_consumed)
    }

    // Flow-style mapping close
    ["}", ..rest] -> {
      let tok = Token(kind: FlowMapEnd, position: Position(line_num, col))
      let new_depth = case flow_depth > 0 {
        True -> flow_depth - 1
        False -> 0
      }
      tokenize_content_ml(rest, line_num, col + 1, new_depth, [tok, ..acc], rest_raw, extra_consumed)
    }

    // Comma — separator inside flow collections only
    [",", ..rest] if flow_depth > 0 -> {
      let tok = Token(kind: Comma, position: Position(line_num, col))
      tokenize_content_ml(rest, line_num, col + 1, flow_depth, [tok, ..acc], rest_raw, extra_consumed)
    }

    ["&", ..rest] ->
      case read_node_name(rest, col + 1, []) {
        Error(e) -> Error(e)
        Ok(#("", _, _)) ->
          Error(ParseError(
            message: "expected anchor name after '&'",
            line: line_num,
            column: col + 1,
          ))
        Ok(#(name, remaining, new_col)) -> {
          let tok =
            Token(kind: AnchorMarker(name), position: Position(line_num, col))
          tokenize_content_ml(remaining, line_num, new_col, flow_depth, [
            tok,
            ..acc
          ], rest_raw, extra_consumed)
        }
      }

    ["*", ..rest] ->
      case read_node_name(rest, col + 1, []) {
        Error(e) -> Error(e)
        Ok(#("", _, _)) ->
          Error(ParseError(
            message: "expected alias name after '*'",
            line: line_num,
            column: col + 1,
          ))
        Ok(#(name, remaining, new_col)) -> {
          let tok =
            Token(kind: AliasMarker(name), position: Position(line_num, col))
          tokenize_content_ml(remaining, line_num, new_col, flow_depth, [
            tok,
            ..acc
          ], rest_raw, extra_consumed)
        }
      }

    ["!", ..] ->
      Error(Unsupported(
        feature: "tags ('!type')",
        line: line_num,
        column: col,
      ))

    // Anything else: plain scalar
    _ -> read_plain_then_continue_ml(graphemes, line_num, col, flow_depth, acc, rest_raw, extra_consumed)
  }
}

/// End of a source line. Outside flow context the logical line ends here.
/// Inside an open flow collection, tokenizing continues on the next source
/// line, so a collection spanning several lines becomes one logical line
/// whose tokens keep their own positions. Blank and comment-only lines
/// inside the collection are skipped; a document marker is an error.
fn end_of_line(
  line_num: Int,
  flow_depth: Int,
  acc: List(Token),
  rest_raw: List(String),
  extra_consumed: Int,
) -> Result(#(List(Token), Option(PendingBlock), List(String), Int), YamlError) {
  case flow_depth > 0, rest_raw {
    False, _ | True, [] ->
      Ok(#(list.reverse(acc), None, rest_raw, extra_consumed))
    True, [next_line, ..rest_rest] -> {
      let next_num = line_num + 1
      let trimmed = string.trim_start(next_line)
      let graphemes = string.to_graphemes(trimmed)
      let indent_len = string.length(next_line) - string.length(trimmed)
      case indent_len, try_document_marker(graphemes, next_num) {
        0, Some(_) ->
          Error(ParseError(
            message: "document marker inside flow collection; close it with ']' or '}' first",
            line: next_num,
            column: 1,
          ))
        _, _ ->
          tokenize_content_ml(
            graphemes,
            next_num,
            indent_len + 1,
            flow_depth,
            acc,
            rest_rest,
            extra_consumed + 1,
          )
      }
    }
  }
}

/// Inside flow context, a `:` directly after a JSON-like node (a quoted
/// scalar or a closed flow collection) is a value indicator even with no
/// space after it (YAML 1.2 §7.4.2), so `{"a":1}` reads as JSON does.
fn follows_json_node(flow_depth: Int, acc: List(Token)) -> Bool {
  case flow_depth > 0, acc {
    True, [Token(kind: QuotedScalar(_), ..), ..] -> True
    True, [Token(kind: FlowSeqEnd, ..), ..] -> True
    True, [Token(kind: FlowMapEnd, ..), ..] -> True
    _, _ -> False
  }
}

fn read_plain_then_continue_ml(
  graphemes: List(String),
  line_num: Int,
  col: Int,
  flow_depth: Int,
  acc: List(Token),
  rest_raw: List(String),
  extra_consumed: Int,
) -> Result(#(List(Token), Option(PendingBlock), List(String), Int), YamlError) {
  let #(text, remaining, new_col) =
    read_plain_scalar(graphemes, col, flow_depth, [])
  case text, remaining {
    "", _ -> Ok(#(list.reverse(acc), None, rest_raw, extra_consumed))
    // The scalar reached the end of its line, so it may continue on the
    // lines that follow.
    _, [] -> {
      let parent_indent = plain_parent_indent(acc, col)
      use continued <- result.try(continue_plain(
        text,
        line_num,
        new_col,
        parent_indent,
        flow_depth,
        rest_raw,
        extra_consumed,
      ))
      let tok =
        Token(
          kind: PlainScalar(continued.text),
          position: Position(line_num, col),
        )
      tokenize_content_ml(
        continued.remaining,
        continued.line,
        continued.column,
        flow_depth,
        [tok, ..acc],
        continued.rest_raw,
        continued.extra_consumed,
      )
    }
    _, _ -> {
      let tok =
        Token(kind: PlainScalar(text), position: Position(line_num, col))
      tokenize_content_ml(
        remaining,
        line_num,
        new_col,
        flow_depth,
        [tok, ..acc],
        rest_raw,
        extra_consumed,
      )
    }
  }
}

/// Where a plain scalar's continuation stopped: the folded text, and the
/// rest of the last line it read, which tokenizing resumes from.
type PlainContinuation {
  PlainContinuation(
    text: String,
    remaining: List(String),
    line: Int,
    column: Int,
    rest_raw: List(String),
    extra_consumed: Int,
  )
}

/// The indentation of the block node that holds a plain scalar starting
/// at `col`, given the tokens before it on its line (most recent first).
/// In block context a continuation line must be indented more than this
/// (YAML 1.2 §7.3.3), so a sibling key or sequence item never reads as
/// part of the scalar.
///
/// - A mapping value (`key: text`, `- key: text`): the key's indentation.
/// - A sequence item (`- text`): the dash's indentation.
/// - A scalar alone on its line: one less than its own indentation, so
///   continuation lines may align with its first line.
fn plain_parent_indent(acc: List(Token), col: Int) -> Int {
  let since_dash = list.take_while(acc, fn(tok) { tok.kind != Dash })
  let first_column = case list.last(since_dash) {
    Ok(tok) -> tok.position.column
    Error(Nil) -> col
  }
  let has_colon = list.any(since_dash, fn(tok) { tok.kind == Colon })
  case has_colon, list.drop(acc, list.length(since_dash)) {
    True, _ -> first_column - 1
    False, [dash, ..] -> dash.position.column - 1
    False, [] -> first_column - 2
  }
}

/// Fold the lines that continue a plain scalar (YAML 1.2 §7.3.3). A line
/// break between two content lines becomes a space, and each empty line
/// between them becomes a `\n`. A continuation line must be indented more
/// than `parent_indent` in block context, and it may not be a comment or a
/// document marker; inside a flow collection, any line that starts with
/// plain content continues the scalar. Blank lines that lead to no
/// continuation are left unread. A `:` after a continued scalar is an
/// error, because a mapping key must fit on one line.
fn continue_plain(
  text: String,
  line_num: Int,
  col: Int,
  parent_indent: Int,
  flow_depth: Int,
  rest_raw: List(String),
  extra_consumed: Int,
) -> Result(PlainContinuation, YamlError) {
  let stop =
    Ok(PlainContinuation(text, [], line_num, col, rest_raw, extra_consumed))
  let blank = list.take_while(rest_raw, fn(raw) { string.trim(raw) == "" })
  let blank_count = list.length(blank)
  case list.drop(rest_raw, blank_count) {
    [] -> stop
    [next, ..rest_rest] -> {
      let next_num = line_num + blank_count + 1
      case validate_indent(string.to_graphemes(next), next_num) {
        Error(_) -> stop
        Ok(#(indent, content)) -> {
          let continues =
            { flow_depth > 0 || indent > parent_indent }
            && !{
              indent == 0 && try_document_marker(content, next_num) != None
            }
          let #(more, remaining, new_col) =
            read_plain_scalar(content, indent + 1, flow_depth, [])
          case continues, more, content {
            False, _, _ | _, "", _ | _, _, ["#", ..] -> stop
            True, _, _ -> {
              let separator = case blank_count {
                0 -> " "
                _ -> string.repeat("\n", blank_count)
              }
              let joined = text <> separator <> more
              let consumed = extra_consumed + blank_count + 1
              case remaining {
                [] ->
                  continue_plain(
                    joined,
                    next_num,
                    new_col,
                    parent_indent,
                    flow_depth,
                    rest_rest,
                    consumed,
                  )
                [":", ..] ->
                  Error(ParseError(
                    message: "unexpected ':' after a plain scalar that spans lines; a mapping key must fit on one line",
                    line: next_num,
                    column: new_col,
                  ))
                _ ->
                  Ok(PlainContinuation(
                    joined,
                    remaining,
                    next_num,
                    new_col,
                    rest_rest,
                    consumed,
                  ))
              }
            }
          }
        }
      }
    }
  }
}

/// Read a plain scalar starting at the current position. Stops at any
/// terminator without consuming it. Trailing whitespace is trimmed.
fn read_plain_scalar(
  remaining: List(String),
  col: Int,
  flow_depth: Int,
  acc: List(String),
) -> #(String, List(String), Int) {
  case remaining {
    [] -> #(finalize_plain(acc), [], col)
    [c, ..rest] ->
      case is_plain_terminator(c, rest, flow_depth) {
        True -> #(finalize_plain(acc), remaining, col)
        False -> read_plain_scalar(rest, col + 1, flow_depth, [c, ..acc])
      }
  }
}

fn finalize_plain(acc: List(String)) -> String {
  acc
  |> list.reverse
  |> string.join("")
  |> string.trim_end
}

/// Read an anchor or alias name from the source. The name consists of
/// alphanumeric characters, hyphens, and underscores. Stops at the first
/// character that doesn't match.
fn read_node_name(
  remaining: List(String),
  col: Int,
  acc: List(String),
) -> Result(#(String, List(String), Int), YamlError) {
  case remaining {
    [] -> {
      let name = acc |> list.reverse |> string.join("")
      Ok(#(name, [], col))
    }
    [c, ..rest] ->
      case is_node_name_char(c) {
        True -> read_node_name(rest, col + 1, [c, ..acc])
        False -> {
          let name = acc |> list.reverse |> string.join("")
          Ok(#(name, remaining, col))
        }
      }
  }
}

fn is_node_name_char(c: String) -> Bool {
  case c {
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    "a" | "b" | "c" | "d" | "e" | "f" | "g" | "h" | "i" | "j" -> True
    "k" | "l" | "m" | "n" | "o" | "p" | "q" | "r" | "s" | "t" -> True
    "u" | "v" | "w" | "x" | "y" | "z" -> True
    "A" | "B" | "C" | "D" | "E" | "F" | "G" | "H" | "I" | "J" -> True
    "K" | "L" | "M" | "N" | "O" | "P" | "Q" | "R" | "S" | "T" -> True
    "U" | "V" | "W" | "X" | "Y" | "Z" -> True
    "_" | "-" -> True
    _ -> False
  }
}

/// A character terminates a plain scalar when:
/// - It's `:` followed by space or end of line (mapping separator)
/// - It's ` ` followed by `#` (inline comment)
/// - In flow context only: `,`, `]`, `}` (flow indicators)
/// Block context allows `,`, `]`, `}` as valid plain scalar characters.
fn is_plain_terminator(c: String, rest: List(String), flow_depth: Int) -> Bool {
  case c {
    "," | "]" | "}" -> flow_depth > 0
    ":" ->
      case rest {
        [] -> True
        [" ", ..] -> True
        _ -> False
      }
    " " ->
      case rest {
        ["#", ..] -> True
        _ -> False
      }
    _ -> False
  }
}

fn is_separator_followup(rest: List(String)) -> Bool {
  case rest {
    [] -> True
    [" ", ..] -> True
    _ -> False
  }
}

// ── Quoted scalar readers ───────────────────────────────────────────────────

/// Single-quoted string reader. `''` is an escaped quote, and a string
/// that continues past its line folds the break as a double-quoted string
/// does (YAML 1.2 §7.3.2): a space, or one `\n` per empty line between.
/// `white` holds the spaces and tabs since the last content character,
/// most recent first, which a line break drops.
fn read_single_quoted(
  remaining: List(String),
  line_num: Int,
  col: Int,
  acc: List(String),
  white: List(String),
  rest_raw: List(String),
  extra_consumed: Int,
) -> Result(#(String, List(String), Int, List(String), Int), YamlError) {
  case remaining {
    [] -> fold_single_quoted(line_num, col, acc, 0, rest_raw, extra_consumed)
    ["'", "'", ..rest] ->
      read_single_quoted(
        rest,
        line_num,
        col + 2,
        ["'", ..list.append(white, acc)],
        [],
        rest_raw,
        extra_consumed,
      )
    ["'", ..rest] -> {
      let text = list.append(white, acc) |> list.reverse |> string.join("")
      Ok(#(text, rest, col + 1, rest_raw, extra_consumed))
    }
    [" " as c, ..rest] | ["\t" as c, ..rest] ->
      read_single_quoted(
        rest,
        line_num,
        col + 1,
        acc,
        [c, ..white],
        rest_raw,
        extra_consumed,
      )
    [c, ..rest] ->
      read_single_quoted(
        rest,
        line_num,
        col + 1,
        [c, ..list.append(white, acc)],
        [],
        rest_raw,
        extra_consumed,
      )
  }
}

/// Continue a single-quoted string on the next non-empty line, counting
/// the empty lines on the way. The error for a string that never closes
/// points at the end of the line where it was last open.
fn fold_single_quoted(
  line_num: Int,
  col: Int,
  acc: List(String),
  empty_lines: Int,
  rest_raw: List(String),
  extra_consumed: Int,
) -> Result(#(String, List(String), Int, List(String), Int), YamlError) {
  case rest_raw {
    [] ->
      Error(ParseError(
        message: "unterminated single-quoted string",
        line: line_num - empty_lines,
        column: col,
      ))
    [next_line, ..rest_rest] -> {
      let trimmed = string.trim_start(next_line)
      case trimmed {
        "" ->
          fold_single_quoted(
            line_num + 1,
            col,
            acc,
            empty_lines + 1,
            rest_rest,
            extra_consumed + 1,
          )
        _ -> {
          let separator = case empty_lines {
            0 -> " "
            _ -> string.repeat("\n", empty_lines)
          }
          let indent_len = string.length(next_line) - string.length(trimmed)
          read_single_quoted(
            string.to_graphemes(trimmed),
            line_num + 1,
            indent_len + 1,
            [separator, ..acc],
            [],
            rest_rest,
            extra_consumed + 1,
          )
        }
      }
    }
  }
}

/// Multi-line aware double-quoted string reader.
/// When the closing `"` is not found on the current line, consumes the next
/// raw line from `rest_raw`, folds the line break (per YAML 1.2 §7.3.1),
/// and continues scanning.
///
/// `white` holds the literal spaces and tabs seen since the last content
/// character, most recent first. They join `acc` when more content follows
/// on the same line, and are dropped at a line break, because folding
/// excludes trailing white space.
fn read_double_quoted_ml(
  remaining: List(String),
  line_num: Int,
  col: Int,
  acc: List(String),
  white: List(String),
  rest_raw: List(String),
  extra_consumed: Int,
) -> Result(#(String, List(String), Int, List(String), Int), YamlError) {
  case remaining {
    // End of current line — fold the break into a space
    [] -> fold_double_quoted(line_num, col, acc, " ", rest_raw, extra_consumed)
    // Escaped line break — join with the next line, no space
    ["\\"] ->
      fold_double_quoted(
        line_num,
        col,
        list.append(white, acc),
        "",
        rest_raw,
        extra_consumed,
      )
    ["\\", ..rest] ->
      case decode_escape(rest) {
        Ok(#(text, after, width)) ->
          read_double_quoted_ml(
            after,
            line_num,
            col + 1 + width,
            [text, ..list.append(white, acc)],
            [],
            rest_raw,
            extra_consumed,
          )
        Error(Nil) ->
          Error(ParseError(
            message: "invalid escape '\\"
              <> first_or_empty(rest)
              <> "' in double-quoted string",
            line: line_num,
            column: col,
          ))
      }
    ["\"", ..rest] -> {
      let text = list.append(white, acc) |> list.reverse |> string.join("")
      Ok(#(text, rest, col + 1, rest_raw, extra_consumed))
    }
    [" " as c, ..rest] | ["\t" as c, ..rest] ->
      read_double_quoted_ml(rest, line_num, col + 1, acc, [c, ..white], rest_raw, extra_consumed)
    [c, ..rest] ->
      read_double_quoted_ml(rest, line_num, col + 1, [c, ..list.append(white, acc)], [], rest_raw, extra_consumed)
  }
}

/// Fold a line break inside a double-quoted string (YAML 1.2 §7.3.1).
/// Consumes the next raw line along with any empty lines before it. Each
/// empty line becomes a `\n`; with none, the break becomes `separator`
/// (a space, or nothing after an escaped line break). Leading white space
/// on the continuation line is dropped.
fn fold_double_quoted(
  line_num: Int,
  col: Int,
  acc: List(String),
  separator: String,
  rest_raw: List(String),
  extra_consumed: Int,
) -> Result(#(String, List(String), Int, List(String), Int), YamlError) {
  case rest_raw {
    [] ->
      Error(ParseError(
        message: "unterminated double-quoted string",
        line: line_num,
        column: col,
      ))
    [next_line, ..rest_rest] -> {
      let trimmed = string.trim_start(next_line)
      case trimmed {
        "" ->
          fold_double_quoted(
            line_num + 1,
            1,
            ["\n", ..acc],
            "",
            rest_rest,
            extra_consumed + 1,
          )
        _ -> {
          let indent_len = string.length(next_line) - string.length(trimmed)
          let acc2 = case separator {
            "" -> acc
            _ -> [separator, ..acc]
          }
          read_double_quoted_ml(
            string.to_graphemes(trimmed),
            line_num + 1,
            indent_len + 1,
            acc2,
            [],
            rest_rest,
            extra_consumed + 1,
          )
        }
      }
    }
  }
}

/// Decode the escape sequence after a `\` in a double-quoted string
/// (YAML 1.2 §5.7). Returns the decoded text, the graphemes after the
/// sequence, and how many graphemes the sequence used.
fn decode_escape(
  graphemes: List(String),
) -> Result(#(String, List(String), Int), Nil) {
  case graphemes {
    ["0", ..rest] -> Ok(#("\u{0000}", rest, 1))
    ["a", ..rest] -> Ok(#("\u{0007}", rest, 1))
    ["b", ..rest] -> Ok(#("\u{0008}", rest, 1))
    ["t", ..rest] | ["\t", ..rest] -> Ok(#("\t", rest, 1))
    ["n", ..rest] -> Ok(#("\n", rest, 1))
    ["v", ..rest] -> Ok(#("\u{000B}", rest, 1))
    ["f", ..rest] -> Ok(#("\u{000C}", rest, 1))
    ["r", ..rest] -> Ok(#("\r", rest, 1))
    ["e", ..rest] -> Ok(#("\u{001B}", rest, 1))
    [" ", ..rest] -> Ok(#(" ", rest, 1))
    ["\"", ..rest] -> Ok(#("\"", rest, 1))
    ["/", ..rest] -> Ok(#("/", rest, 1))
    ["\\", ..rest] -> Ok(#("\\", rest, 1))
    ["N", ..rest] -> Ok(#("\u{0085}", rest, 1))
    ["_", ..rest] -> Ok(#("\u{00A0}", rest, 1))
    ["L", ..rest] -> Ok(#("\u{2028}", rest, 1))
    ["P", ..rest] -> Ok(#("\u{2029}", rest, 1))
    ["x", ..rest] -> decode_code_point(rest, 2)
    ["u", ..rest] ->
      case decode_hex(rest, 4) {
        Ok(#(high, after)) if high >= 0xD800 && high <= 0xDBFF ->
          decode_surrogate_pair(high, after)
        Ok(#(value, after)) -> code_point_text(value, after, 5)
        Error(Nil) -> Error(Nil)
      }
    ["U", ..rest] -> decode_code_point(rest, 8)
    _ -> Error(Nil)
  }
}

/// Decode the `digits` hex digits of a `\x` or `\U` escape into the
/// character they name.
fn decode_code_point(
  graphemes: List(String),
  digits: Int,
) -> Result(#(String, List(String), Int), Nil) {
  case decode_hex(graphemes, digits) {
    Ok(#(value, after)) -> code_point_text(value, after, 1 + digits)
    Error(Nil) -> Error(Nil)
  }
}

/// JSON writes characters past U+FFFF as a UTF-16 surrogate pair, such
/// as `\uD83D\uDE00`. Combine a high surrogate with the low surrogate
/// escape that must follow it; a lone surrogate is rejected.
fn decode_surrogate_pair(
  high: Int,
  graphemes: List(String),
) -> Result(#(String, List(String), Int), Nil) {
  case graphemes {
    ["\\", "u", ..rest] ->
      case decode_hex(rest, 4) {
        Ok(#(low, after)) if low >= 0xDC00 && low <= 0xDFFF ->
          code_point_text(
            0x10000 + { high - 0xD800 } * 0x400 + { low - 0xDC00 },
            after,
            11,
          )
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

/// Read exactly `digits` hex digits as an integer.
fn decode_hex(
  graphemes: List(String),
  digits: Int,
) -> Result(#(Int, List(String)), Nil) {
  let hex = list.take(graphemes, digits)
  case list.length(hex) == digits && list.all(hex, is_hex_digit) {
    False -> Error(Nil)
    True ->
      case int.base_parse(string.join(hex, ""), 16) {
        Ok(value) -> Ok(#(value, list.drop(graphemes, digits)))
        Error(_) -> Error(Nil)
      }
  }
}

/// The character for code point `value`, after an escape `width`
/// graphemes long. Surrogates and values past U+10FFFF are rejected.
fn code_point_text(
  value: Int,
  after: List(String),
  width: Int,
) -> Result(#(String, List(String), Int), Nil) {
  case string.utf_codepoint(value) {
    Ok(codepoint) ->
      Ok(#(string.from_utf_codepoints([codepoint]), after, width))
    Error(_) -> Error(Nil)
  }
}

fn is_hex_digit(c: String) -> Bool {
  case c {
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    "a" | "b" | "c" | "d" | "e" | "f" -> True
    "A" | "B" | "C" | "D" | "E" | "F" -> True
    _ -> False
  }
}

fn first_or_empty(graphemes: List(String)) -> String {
  case graphemes {
    [c, ..] -> c
    [] -> ""
  }
}

// ── Block scalar header parsing ─────────────────────────────────────────────

/// After `|`, the rest of the line may contain (in order):
///   - an optional chomping indicator: `-` (strip) or `+` (keep)
///   - whitespace
///   - an optional `# comment`
///   - end of line
/// Anything else is a parse error.
fn parse_block_scalar_header(
  graphemes: List(String),
  line_num: Int,
  col: Int,
) -> Result(BlockChomping, YamlError) {
  let #(chomping, after_chomping) = case graphemes {
    ["-", ..rest] -> #(Strip, rest)
    ["+", ..rest] -> #(Keep, rest)
    _ -> #(Clip, graphemes)
  }
  case is_only_whitespace_or_comment(after_chomping) {
    True -> Ok(chomping)
    False ->
      Error(ParseError(
        message: "unexpected content after block scalar opener; only whitespace or '# comment' allowed",
        line: line_num,
        column: col,
      ))
  }
}

fn is_only_whitespace_or_comment(graphemes: List(String)) -> Bool {
  case graphemes {
    [] -> True
    [" ", ..rest] -> is_only_whitespace_or_comment(rest)
    ["#", ..] -> True
    _ -> False
  }
}

// ── Block scalar reader ─────────────────────────────────────────────────────

/// Read a block scalar's content from the source lines following the
/// line that contained the `|` or `>` opener. Returns the content text,
/// the remaining raw lines, and the count of consumed lines. Dispatches
/// on `style` to choose literal or folded joining semantics.
fn read_block_scalar(
  rest_raw: List(String),
  parent_indent: Int,
  style: BlockStyle,
  chomping: BlockChomping,
) -> #(String, List(String), Int) {
  let #(content_lines_raw, new_rest, consumed) =
    collect_block_lines(rest_raw, parent_indent, [], 0)

  let content_indent =
    detect_content_indent(content_lines_raw, parent_indent + 1)

  let raw_joined = case style {
    Literal -> {
      // Literal: each line keeps its original (un-folded) line break
      let stripped =
        list.map(content_lines_raw, fn(line) {
          case is_blank_line(line) {
            True -> ""
            False -> drop_leading_spaces(line, content_indent)
          }
        })
      lines_to_text(stripped)
    }
    Folded -> fold_lines_to_text(content_lines_raw, content_indent)
  }

  let final = apply_chomping(raw_joined, chomping)
  #(final, new_rest, consumed)
}

/// Walk source lines collecting the block scalar's content. The first
/// non-blank line determines the "content indent" — subsequent non-blank
/// lines must be at that column or deeper. Blank lines are always
/// collected. The block ends at the first non-blank line that drops
/// below the content indent.
///
/// This is the contextual rule that correctly stops `- description: >`
/// at a sibling `  id: s1` inside the same sequence item.
fn collect_block_lines(
  remaining: List(String),
  parent_indent: Int,
  acc: List(String),
  count: Int,
) -> #(List(String), List(String), Int) {
  do_collect_block(remaining, parent_indent, None, acc, count)
}

fn do_collect_block(
  remaining: List(String),
  parent_indent: Int,
  detected: Option(Int),
  acc: List(String),
  count: Int,
) -> #(List(String), List(String), Int) {
  case remaining {
    [] -> #(list.reverse(acc), [], count)
    [line, ..rest] -> {
      case is_blank_line(line) {
        True ->
          do_collect_block(
            rest,
            parent_indent,
            detected,
            [line, ..acc],
            count + 1,
          )
        False -> {
          let line_indent = count_leading_spaces_in_line(line)
          case detected {
            None ->
              case line_indent > parent_indent {
                True ->
                  do_collect_block(
                    rest,
                    parent_indent,
                    Some(line_indent),
                    [line, ..acc],
                    count + 1,
                  )
                False -> #(list.reverse(acc), remaining, count)
              }
            Some(ci) ->
              case line_indent >= ci {
                True ->
                  do_collect_block(
                    rest,
                    parent_indent,
                    detected,
                    [line, ..acc],
                    count + 1,
                  )
                False -> #(list.reverse(acc), remaining, count)
              }
          }
        }
      }
    }
  }
}

/// Determine the content indent for a block scalar. Defaults to
/// `default_indent` if there are no non-blank lines.
fn detect_content_indent(lines: List(String), default_indent: Int) -> Int {
  case lines {
    [] -> default_indent
    [first, ..rest] ->
      case is_blank_line(first) {
        True -> detect_content_indent(rest, default_indent)
        False -> count_leading_spaces_in_line(first)
      }
  }
}

fn drop_leading_spaces(line: String, n: Int) -> String {
  case n <= 0 {
    True -> line
    False ->
      case string.starts_with(line, " ") {
        True -> drop_leading_spaces(string.drop_start(line, 1), n - 1)
        False -> line
      }
  }
}

fn count_leading_spaces_in_line(line: String) -> Int {
  do_count_leading(string.to_graphemes(line), 0)
}

fn do_count_leading(graphemes: List(String), n: Int) -> Int {
  case graphemes {
    [" ", ..rest] -> do_count_leading(rest, n + 1)
    _ -> n
  }
}

fn is_blank_line(line: String) -> Bool {
  case string.trim(line) {
    "" -> True
    _ -> False
  }
}

/// Each line gets a trailing `\n`. The result is a single string with
/// all the line breaks present, ready for chomping to adjust the trailing
/// newlines.
fn lines_to_text(lines: List(String)) -> String {
  do_lines_to_text(lines, "")
}

fn do_lines_to_text(lines: List(String), acc: String) -> String {
  case lines {
    [] -> acc
    [line, ..rest] -> do_lines_to_text(rest, acc <> line <> "\n")
  }
}

// ── Folded block scalar — line classification + state machine ───────────────

/// Each content line is classified into one of three kinds, then a state
/// machine walks the kinds and emits the folded text. The state tracks
/// what was last emitted so we know whether the next line should be
/// joined with a space (continuation of paragraph), with `\n` (more
/// indented or paragraph break), or unprefixed (after a paragraph break).
type FoldLineKind {
  FoldBlank
  FoldNormal(text: String)
  FoldMoreIndented(text: String)
}

type FoldState {
  FoldEmpty
  FoldAfterNormal
  FoldAfterBlank
  FoldAfterMoreIndented
}

fn fold_lines_to_text(lines: List(String), content_indent: Int) -> String {
  let kinds =
    list.map(lines, fn(line) { classify_fold_line(line, content_indent) })
  do_fold_walk(kinds, FoldEmpty, "")
  |> append_block_terminator
}

fn classify_fold_line(line: String, content_indent: Int) -> FoldLineKind {
  case is_blank_line(line) {
    True -> FoldBlank
    False -> {
      let line_indent = count_leading_spaces_in_line(line)
      let stripped = drop_leading_spaces(line, content_indent)
      case line_indent > content_indent {
        True -> FoldMoreIndented(stripped)
        False -> FoldNormal(stripped)
      }
    }
  }
}

fn do_fold_walk(
  remaining: List(FoldLineKind),
  state: FoldState,
  acc: String,
) -> String {
  case remaining {
    [] -> acc
    [kind, ..rest] -> {
      let #(new_state, addition) = fold_transition(state, kind)
      do_fold_walk(rest, new_state, acc <> addition)
    }
  }
}

fn fold_transition(state: FoldState, kind: FoldLineKind) -> #(FoldState, String) {
  case state, kind {
    // From Empty (no content emitted yet)
    FoldEmpty, FoldBlank -> #(FoldAfterBlank, "")
    FoldEmpty, FoldNormal(t) -> #(FoldAfterNormal, t)
    FoldEmpty, FoldMoreIndented(t) -> #(FoldAfterMoreIndented, t)

    // From AfterNormal (last addition was normal-paragraph content)
    FoldAfterNormal, FoldNormal(t) -> #(FoldAfterNormal, " " <> t)
    FoldAfterNormal, FoldBlank -> #(FoldAfterBlank, "\n")
    FoldAfterNormal, FoldMoreIndented(t) -> #(FoldAfterMoreIndented, "\n" <> t)

    // From AfterBlank (we just emitted a "\n" for a blank line)
    FoldAfterBlank, FoldNormal(t) -> #(FoldAfterNormal, t)
    FoldAfterBlank, FoldBlank -> #(FoldAfterBlank, "\n")
    FoldAfterBlank, FoldMoreIndented(t) -> #(FoldAfterMoreIndented, t)

    // From AfterMoreIndented (last addition was preserved indented content)
    FoldAfterMoreIndented, FoldNormal(t) -> #(FoldAfterNormal, "\n" <> t)
    FoldAfterMoreIndented, FoldBlank -> #(FoldAfterBlank, "\n")
    FoldAfterMoreIndented, FoldMoreIndented(t) -> #(
      FoldAfterMoreIndented,
      "\n" <> t,
    )
  }
}

/// After the fold state machine runs, we unconditionally append one more
/// `\n` to represent the "implicit terminator" of the final content line.
/// The state machine emits N-1 separators between N lines but doesn't
/// terminate the last one — so keep chomping was losing a newline.
/// `apply_chomping` operates on the result to adjust to the final count.
fn append_block_terminator(text: String) -> String {
  case text {
    "" -> ""
    _ -> text <> "\n"
  }
}

fn apply_chomping(raw: String, chomping: BlockChomping) -> String {
  case chomping {
    Keep -> raw
    Strip -> trim_trailing_newlines(raw)
    Clip -> {
      let stripped = trim_trailing_newlines(raw)
      case stripped {
        "" -> ""
        _ -> stripped <> "\n"
      }
    }
  }
}

fn trim_trailing_newlines(text: String) -> String {
  case string.ends_with(text, "\n") {
    True -> trim_trailing_newlines(string.drop_end(text, 1))
    False -> text
  }
}
