//// Token type emitted by the lexer.
////
//// yamleam uses a line-oriented lexer: each logical (non-blank,
//// non-comment) line is converted into a list of tokens together with
//// the line's indent column. The parser consumes these line-token groups.

import yamleam/position.{type Position}

pub type TokenKind {
  /// A plain (unquoted) scalar — the text as written, not yet type-resolved.
  PlainScalar(text: String)
  /// A quoted scalar — string contents with escapes already decoded.
  /// Always decoded to a YamlString regardless of content.
  QuotedScalar(text: String)
  /// The `:` separator of a mapping entry.
  Colon
  /// The `-` marker opening a block-sequence item.
  Dash
  /// The `---` directive end / document start marker. Appears as the
  /// only content of a line at column 1.
  DocumentStart
  /// The `...` document end marker. Appears as the only content of a
  /// line at column 1.
  DocumentEnd
  /// The `[` opening a flow-style sequence.
  FlowSeqStart
  /// The `]` closing a flow-style sequence.
  FlowSeqEnd
  /// The `{` opening a flow-style mapping.
  FlowMapStart
  /// The `}` closing a flow-style mapping.
  FlowMapEnd
  /// The `,` separator between items in a flow collection.
  Comma
  /// An anchor declaration `&name` attached to the next value.
  AnchorMarker(name: String)
  /// An alias reference `*name` substituting a previously-anchored value.
  AliasMarker(name: String)
}

pub type Token {
  Token(kind: TokenKind, position: Position)
}

/// A single logical line of YAML, normalized: blank lines and pure comments
/// are dropped before this form is produced. `indent` is the column of the
/// first non-whitespace character.
pub type Line {
  Line(indent: Int, line_number: Int, tokens: List(Token))
}
