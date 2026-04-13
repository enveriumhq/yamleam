//// Bridge from `YamlNode` to `gleam/dynamic` so that the stdlib
//// `gleam/dynamic/decode` decoders work over a parsed YAML tree.
////
//// The conversion is straightforward because the Erlang term shapes
//// produced by `dynamic.from` for Gleam primitives match what the
//// stdlib decoders expect:
////
//// | YAML | Gleam | Erlang |
//// |---|---|---|
//// | YamlNull | Nil | nil atom |
//// | YamlBool | Bool | true / false atom |
//// | YamlInt | Int | integer |
//// | YamlFloat | Float | float |
//// | YamlString | String | binary |
//// | YamlList | List(Dynamic) | list |
//// | YamlMap | Dict(String, Dynamic) | map |

import gleam/dynamic.{type Dynamic}
import gleam/list
import yamleam/node.{
  type YamlNode, YamlBool, YamlFloat, YamlInt, YamlList, YamlMap, YamlNull,
  YamlString,
}

pub fn to_dynamic(n: YamlNode) -> Dynamic {
  case n {
    YamlNull -> dynamic.nil()
    YamlBool(b) -> dynamic.bool(b)
    YamlInt(i) -> dynamic.int(i)
    YamlFloat(f) -> dynamic.float(f)
    YamlString(s) -> dynamic.string(s)
    YamlList(items) ->
      items
      |> list.map(to_dynamic)
      |> dynamic.list
    YamlMap(pairs) ->
      pairs
      |> list.map(fn(pair) {
        let #(key, value) = pair
        #(dynamic.string(key), to_dynamic(value))
      })
      |> dynamic.properties
  }
}
