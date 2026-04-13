import gleeunit/should
import yamleam/lexer
import yamleam/position.{Position}
import yamleam/token.{
  Colon, Comma, Dash, FlowSeqEnd, FlowSeqStart, Line, PlainScalar, QuotedScalar,
  Token,
}

pub fn empty_source_test() {
  lexer.tokenize("")
  |> should.equal(Ok([]))
}

pub fn blank_lines_test() {
  lexer.tokenize("\n\n\n")
  |> should.equal(Ok([]))
}

pub fn comment_only_test() {
  lexer.tokenize("# just a comment\n")
  |> should.equal(Ok([]))
}

pub fn single_key_value_test() {
  let assert Ok(lines) = lexer.tokenize("name: Alice")
  case lines {
    [Line(indent: 1, line_number: 1, tokens: tokens)] -> {
      tokens
      |> should.equal([
        Token(kind: PlainScalar("name"), position: Position(1, 1)),
        Token(kind: Colon, position: Position(1, 5)),
        Token(kind: PlainScalar("Alice"), position: Position(1, 7)),
      ])
    }
    _ -> should.fail()
  }
}

pub fn nested_mapping_test() {
  let source = "outer:\n  inner: value"
  let assert Ok(lines) = lexer.tokenize(source)
  case lines {
    [
      Line(indent: 1, line_number: 1, tokens: t1),
      Line(indent: 3, line_number: 2, tokens: t2),
    ] -> {
      // Line 1: outer:
      case t1 {
        [
          Token(kind: PlainScalar("outer"), position: _),
          Token(kind: Colon, position: _),
        ] -> Nil
        _ -> should.fail()
      }
      // Line 2: inner: value (with indent 3)
      case t2 {
        [
          Token(kind: PlainScalar("inner"), position: _),
          Token(kind: Colon, position: _),
          Token(kind: PlainScalar("value"), position: _),
        ] -> Nil
        _ -> should.fail()
      }
    }
    _ -> should.fail()
  }
}

pub fn sequence_test() {
  let source = "items:\n  - a\n  - b\n  - c"
  let assert Ok(lines) = lexer.tokenize(source)
  case lines {
    [
      Line(indent: 1, ..),
      Line(indent: 3, tokens: t2, ..),
      Line(indent: 3, tokens: t3, ..),
      Line(indent: 3, tokens: t4, ..),
    ] -> {
      case t2 {
        [Token(kind: Dash, ..), Token(kind: PlainScalar("a"), ..)] -> Nil
        _ -> should.fail()
      }
      let _ = t3
      let _ = t4
      Nil
    }
    _ -> should.fail()
  }
}

pub fn dash_with_inline_mapping_test() {
  let source = "- id: s1\n  title: First"
  let assert Ok(lines) = lexer.tokenize(source)
  case lines {
    [Line(indent: 1, tokens: t1, ..), Line(indent: 3, tokens: t2, ..)] -> {
      case t1 {
        [
          Token(kind: Dash, position: Position(1, 1)),
          Token(kind: PlainScalar("id"), position: Position(1, 3)),
          Token(kind: Colon, position: _),
          Token(kind: PlainScalar("s1"), position: _),
        ] -> Nil
        _ -> should.fail()
      }
      let _ = t2
      Nil
    }
    _ -> should.fail()
  }
}

pub fn single_quoted_test() {
  let source = "name: 'Alice''s'"
  let assert Ok(lines) = lexer.tokenize(source)
  case lines {
    [Line(tokens: tokens, ..)] -> {
      case tokens {
        [
          Token(kind: PlainScalar("name"), ..),
          Token(kind: Colon, ..),
          Token(kind: QuotedScalar("Alice's"), ..),
        ] -> Nil
        _ -> should.fail()
      }
    }
    _ -> should.fail()
  }
}

pub fn double_quoted_with_escapes_test() {
  let source = "msg: \"hello\\nworld\""
  let assert Ok(lines) = lexer.tokenize(source)
  case lines {
    [Line(tokens: tokens, ..)] -> {
      case tokens {
        [
          Token(kind: PlainScalar("msg"), ..),
          Token(kind: Colon, ..),
          Token(kind: QuotedScalar("hello\nworld"), ..),
        ] -> Nil
        _ -> should.fail()
      }
    }
    _ -> should.fail()
  }
}

pub fn inline_comment_test() {
  let source = "name: Alice # this is the user"
  let assert Ok(lines) = lexer.tokenize(source)
  case lines {
    [Line(tokens: tokens, ..)] -> {
      case tokens {
        [
          Token(kind: PlainScalar("name"), ..),
          Token(kind: Colon, ..),
          Token(kind: PlainScalar("Alice"), ..),
        ] -> Nil
        _ -> should.fail()
      }
    }
    _ -> should.fail()
  }
}

pub fn tab_in_indent_rejected_test() {
  let source = "\tname: Alice"
  let result = lexer.tokenize(source)
  case result {
    Error(_) -> Nil
    Ok(_) -> should.fail()
  }
}

pub fn flow_style_tokenized_test() {
  // Flow style is supported as of v0.4. Verify tokens, not rejection.
  let source = "items: [1, 2, 3]"
  let assert Ok(lines) = lexer.tokenize(source)
  case lines {
    [Line(tokens: tokens, ..)] -> {
      // Expect: PlainScalar("items"), Colon, FlowSeqStart,
      // PlainScalar("1"), Comma, PlainScalar("2"), Comma,
      // PlainScalar("3"), FlowSeqEnd
      case tokens {
        [
          Token(kind: PlainScalar("items"), ..),
          Token(kind: Colon, ..),
          Token(kind: FlowSeqStart, ..),
          Token(kind: PlainScalar("1"), ..),
          Token(kind: Comma, ..),
          Token(kind: PlainScalar("2"), ..),
          Token(kind: Comma, ..),
          Token(kind: PlainScalar("3"), ..),
          Token(kind: FlowSeqEnd, ..),
        ] -> Nil
        _ -> should.fail()
      }
    }
    _ -> should.fail()
  }
}
