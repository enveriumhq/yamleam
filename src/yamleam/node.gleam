//// The typed YAML node tree.
////
//// `YamlNode` is the output of `yamleam.parse_raw`. It's also the
//// input to the decoder layer. Pattern-match on it directly if you
//// want raw access to the tree.

pub type YamlNode {
  YamlNull
  YamlBool(Bool)
  YamlInt(Int)
  YamlFloat(Float)
  YamlString(String)
  YamlList(List(YamlNode))
  YamlMap(List(#(String, YamlNode)))
}

/// The YAML tree with every number kept exactly as written.
///
/// `yamleam/exact` returns it. It has the shape of `YamlNode`, except that
/// a plain scalar that `YamlNode` resolves to `YamlInt` or `YamlFloat` is an
/// `ExactNumber` carrying the scalar's own text: `0.0323`, `12.50`, `-0`,
/// `+1.5e3`. Use it when a number must not pass through a `Float`, such as
/// money or a decimal threshold you parse with a decimal library.
pub type ExactNode {
  ExactNull
  ExactBool(Bool)
  ExactNumber(String)
  ExactString(String)
  ExactList(List(ExactNode))
  ExactMap(List(#(String, ExactNode)))
}
