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
