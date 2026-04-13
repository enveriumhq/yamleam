//// Source position tracking.
////
//// `Position` points at a single character in the source. Both fields are
//// 1-indexed so error messages match editor conventions (line 1 is the first
//// line, column 1 is the first character of a line).

pub type Position {
  Position(line: Int, column: Int)
}

/// The position of the first character of any source string.
pub fn start() -> Position {
  Position(line: 1, column: 1)
}

/// Advance the position by one character, handling newline wrap-around.
pub fn advance(pos: Position, char: String) -> Position {
  case char {
    "\n" -> Position(line: pos.line + 1, column: 1)
    _ -> Position(line: pos.line, column: pos.column + 1)
  }
}
