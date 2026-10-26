//// Compact block sequences: a sequence that is a mapping value may put
//// its dashes at the key's own column (YAML 1.2 §8.2.1). This is the
//// style kubectl, GitHub Actions and Ansible tooling emit.

import gleam/dynamic/decode
import gleam/list
import gleeunit/should
import yamleam
import yamleam/node.{YamlInt, YamlList, YamlMap, YamlNull, YamlString}

pub fn top_level_key_test() {
  "steps:
- run: make
- run: test"
  |> yamleam.parse_raw
  |> should.equal(
    Ok(
      YamlMap([
        #(
          "steps",
          YamlList([
            YamlMap([#("run", YamlString("make"))]),
            YamlMap([#("run", YamlString("test"))]),
          ]),
        ),
      ]),
    ),
  )
}

pub fn sibling_key_after_sequence_test() {
  "a:
- 1
- 2
b: 3"
  |> yamleam.parse_raw
  |> should.equal(
    Ok(
      YamlMap([
        #("a", YamlList([YamlInt(1), YamlInt(2)])),
        #("b", YamlInt(3)),
      ]),
    ),
  )
}

pub fn nested_key_test() {
  "spec:
  containers:
  - name: web
    image: nginx
    ports:
    - containerPort: 80
  restartPolicy: Always"
  |> yamleam.parse_raw
  |> should.equal(
    Ok(
      YamlMap([
        #(
          "spec",
          YamlMap([
            #(
              "containers",
              YamlList([
                YamlMap([
                  #("name", YamlString("web")),
                  #("image", YamlString("nginx")),
                  #(
                    "ports",
                    YamlList([YamlMap([#("containerPort", YamlInt(80))])]),
                  ),
                ]),
              ]),
            ),
            #("restartPolicy", YamlString("Always")),
          ]),
        ),
      ]),
    ),
  )
}

pub fn first_key_of_sequence_item_test() {
  "- items:
  - a
  - b
  name: x"
  |> yamleam.parse_raw
  |> should.equal(
    Ok(
      YamlList([
        YamlMap([
          #("items", YamlList([YamlString("a"), YamlString("b")])),
          #("name", YamlString("x")),
        ]),
      ]),
    ),
  )
}

pub fn later_key_of_sequence_item_test() {
  "- name: x
  items:
  - a
- name: y"
  |> yamleam.parse_raw
  |> should.equal(
    Ok(
      YamlList([
        YamlMap([
          #("name", YamlString("x")),
          #("items", YamlList([YamlString("a")])),
        ]),
        YamlMap([#("name", YamlString("y"))]),
      ]),
    ),
  )
}

pub fn empty_items_test() {
  "a:
-
- b"
  |> yamleam.parse_raw
  |> should.equal(Ok(YamlMap([#("a", YamlList([YamlNull, YamlString("b")]))])))
}

pub fn anchored_sequence_test() {
  "base: &list
- a
- b
copy: *list"
  |> yamleam.parse_raw
  |> should.equal(
    Ok(
      YamlMap([
        #("base", YamlList([YamlString("a"), YamlString("b")])),
        #("copy", YamlList([YamlString("a"), YamlString("b")])),
      ]),
    ),
  )
}

pub fn anchored_sequence_in_sequence_item_test() {
  "- name: x
  tags: &t
  - a
  again: *t"
  |> yamleam.parse_raw
  |> should.equal(
    Ok(
      YamlList([
        YamlMap([
          #("name", YamlString("x")),
          #("tags", YamlList([YamlString("a")])),
          #("again", YamlList([YamlString("a")])),
        ]),
      ]),
    ),
  )
}

pub fn indented_sequences_still_work_test() {
  "a:
  - 1
b:
- 2"
  |> yamleam.parse_raw
  |> should.equal(
    Ok(
      YamlMap([
        #("a", YamlList([YamlInt(1)])),
        #("b", YamlList([YamlInt(2)])),
      ]),
    ),
  )
}

pub fn dash_below_key_column_is_not_its_value_test() {
  // `- x` sits left of `inner`, so it can't be inner's value, and `outer`
  // already has a mapping value.
  let assert Error(_) =
    yamleam.parse_raw(
      "outer:
  inner:
- x",
    )
}

pub fn kubectl_deployment_test() {
  let source =
    "apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app: web
  name: web
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - args:
        - --port=8080
        image: ghcr.io/example/web:1.4.2
        name: web
        ports:
        - containerPort: 8080
          protocol: TCP
      - image: ghcr.io/example/sidecar:0.9.0
        name: sidecar
      restartPolicy: Always
"
  let container_names =
    decode.at(
      ["spec", "template", "spec", "containers"],
      decode.list(decode.at(["name"], decode.string)),
    )
  yamleam.parse(source, container_names)
  |> should.equal(Ok(["web", "sidecar"]))

  let args =
    decode.at(
      ["spec", "template", "spec", "containers"],
      decode.list(
        decode.optional_field("args", [], decode.list(decode.string), fn(args) {
          decode.success(args)
        }),
      ),
    )
  yamleam.parse(source, args)
  |> should.equal(Ok([["--port=8080"], []]))
}

pub fn github_actions_workflow_test() {
  let source =
    "name: CI
on:
  push:
    branches:
    - main
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4
    - name: Run tests
      run: |
        gleam test
"
  let assert Ok(YamlMap(workflow)) = yamleam.parse_raw(source)
  let assert Ok(YamlMap(on)) = list.key_find(workflow, "on")
  on
  |> should.equal([
    #("push", YamlMap([#("branches", YamlList([YamlString("main")]))])),
  ])

  let steps =
    decode.at(
      ["jobs", "test", "steps"],
      decode.list(decode.optional_field(
        "run",
        "",
        decode.string,
        decode.success,
      )),
    )
  yamleam.parse(source, steps)
  |> should.equal(Ok(["", "gleam test\n"]))
}

pub fn multi_document_stream_test() {
  "---
kind: ConfigMap
data:
- a
---
kind: Service
ports:
- 80
- 443"
  |> yamleam.parse_documents_raw
  |> should.equal(
    Ok([
      YamlMap([
        #("kind", YamlString("ConfigMap")),
        #("data", YamlList([YamlString("a")])),
      ]),
      YamlMap([
        #("kind", YamlString("Service")),
        #("ports", YamlList([YamlInt(80), YamlInt(443)])),
      ]),
    ]),
  )
}
