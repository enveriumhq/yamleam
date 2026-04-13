//// Multi-document stream tests.

import gleam/dynamic/decode
import gleam/list
import gleeunit/should
import yamleam
import yamleam/error.{ParseError}
import yamleam/node.{YamlInt, YamlMap, YamlString}

pub fn single_document_no_markers_test() {
  let source = "name: alice\nage: 30"
  yamleam.parse_documents_raw(source)
  |> should.equal(
    Ok([YamlMap([#("name", YamlString("alice")), #("age", YamlInt(30))])]),
  )
}

pub fn single_document_with_leading_marker_test() {
  let source = "---\nname: alice"
  yamleam.parse_documents_raw(source)
  |> should.equal(Ok([YamlMap([#("name", YamlString("alice"))])]))
}

pub fn single_document_with_end_marker_test() {
  let source = "name: alice\n..."
  yamleam.parse_documents_raw(source)
  |> should.equal(Ok([YamlMap([#("name", YamlString("alice"))])]))
}

pub fn two_documents_separated_by_start_marker_test() {
  let source = "name: alice\n---\nname: bob"
  yamleam.parse_documents_raw(source)
  |> should.equal(
    Ok([
      YamlMap([#("name", YamlString("alice"))]),
      YamlMap([#("name", YamlString("bob"))]),
    ]),
  )
}

pub fn three_documents_with_all_markers_test() {
  let source =
    "---
name: alice
...
---
name: bob
...
---
name: charlie
..."
  yamleam.parse_documents_raw(source)
  |> should.equal(
    Ok([
      YamlMap([#("name", YamlString("alice"))]),
      YamlMap([#("name", YamlString("bob"))]),
      YamlMap([#("name", YamlString("charlie"))]),
    ]),
  )
}

pub fn kubernetes_style_multi_document_test() {
  // Typical k8s manifest with multiple resources in one file.
  let source =
    "---
kind: ConfigMap
name: app-config
---
kind: Service
name: app-svc
---
kind: Deployment
name: app-deploy"
  yamleam.parse_documents_raw(source)
  |> should.equal(
    Ok([
      YamlMap([
        #("kind", YamlString("ConfigMap")),
        #("name", YamlString("app-config")),
      ]),
      YamlMap([
        #("kind", YamlString("Service")),
        #("name", YamlString("app-svc")),
      ]),
      YamlMap([
        #("kind", YamlString("Deployment")),
        #("name", YamlString("app-deploy")),
      ]),
    ]),
  )
}

pub fn parse_raw_on_multidoc_returns_error_test() {
  // Single-document `parse_raw` rejects multi-document streams so it
  // never silently discards trailing documents.
  let source = "name: alice\n---\nname: bob"
  case yamleam.parse_raw(source) {
    Error(ParseError(message: _, line: 3, column: 1)) -> Nil
    _ -> should.fail()
  }
}

pub fn parse_documents_with_decoder_test() {
  let source =
    "---
name: alice
age: 30
---
name: bob
age: 25"

  let decoder = {
    use name <- decode.field("name", decode.string)
    use age <- decode.field("age", decode.int)
    decode.success(#(name, age))
  }

  yamleam.parse_documents(source, decoder)
  |> should.equal(Ok([#("alice", 30), #("bob", 25)]))
}

pub fn empty_stream_returns_empty_list_test() {
  yamleam.parse_documents_raw("") |> should.equal(Ok([]))
}

pub fn stream_of_only_markers_returns_empty_test() {
  // A stream that's just "---" with nothing after it has no real documents.
  let source = "---"
  let result = yamleam.parse_documents_raw(source)
  case result {
    Ok(docs) ->
      case list.length(docs) {
        0 -> Nil
        _ -> should.fail()
      }
    Error(_) -> should.fail()
  }
}

pub fn document_with_comments_around_markers_test() {
  // Comments between documents are ignored.
  let source =
    "# comment before
---
name: alice
# comment between
---
name: bob
# comment after"
  yamleam.parse_documents_raw(source)
  |> should.equal(
    Ok([
      YamlMap([#("name", YamlString("alice"))]),
      YamlMap([#("name", YamlString("bob"))]),
    ]),
  )
}
