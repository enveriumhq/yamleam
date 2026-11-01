//// Per-document anchor table.
////
//// A pure-Gleam dict mapping anchor names to their resolved YAML values.
//// Threaded explicitly through the parser as a state parameter — the
//// scope is lexically clear: a fresh table at the start of each document
//// (`new/0`), accumulated as anchors are encountered (`set/3`), and
//// looked up at alias sites (`get/2`). Nothing escapes the parser.

import gleam/dict.{type Dict}
import yamleam/node.{type ExactNode}

pub type Anchors =
  Dict(String, ExactNode)

pub fn new() -> Anchors {
  dict.new()
}

pub fn set(anchors: Anchors, name: String, value: ExactNode) -> Anchors {
  dict.insert(anchors, name, value)
}

pub fn get(anchors: Anchors, name: String) -> Result(ExactNode, Nil) {
  dict.get(anchors, name)
}
