import gleeunit/should
import yamleam
import yamleam/node.{
  YamlBool, YamlFloat, YamlInt, YamlList, YamlMap, YamlNull, YamlString,
}

pub fn empty_source_test() {
  yamleam.parse_raw("") |> should.equal(Ok(YamlNull))
}

pub fn single_scalar_test() {
  yamleam.parse_raw("hello") |> should.equal(Ok(YamlString("hello")))
}

pub fn single_int_test() {
  yamleam.parse_raw("42") |> should.equal(Ok(YamlInt(42)))
}

pub fn flat_mapping_test() {
  let source = "name: Alice\nage: 30\nactive: true"
  yamleam.parse_raw(source)
  |> should.equal(
    Ok(
      YamlMap([
        #("name", YamlString("Alice")),
        #("age", YamlInt(30)),
        #("active", YamlBool(True)),
      ]),
    ),
  )
}

pub fn nested_mapping_test() {
  let source = "outer:\n  inner: value"
  yamleam.parse_raw(source)
  |> should.equal(
    Ok(YamlMap([#("outer", YamlMap([#("inner", YamlString("value"))]))])),
  )
}

pub fn deeply_nested_mapping_test() {
  let source = "a:\n  b:\n    c:\n      d: leaf"
  yamleam.parse_raw(source)
  |> should.equal(
    Ok(
      YamlMap([
        #(
          "a",
          YamlMap([
            #("b", YamlMap([#("c", YamlMap([#("d", YamlString("leaf"))]))])),
          ]),
        ),
      ]),
    ),
  )
}

pub fn flat_sequence_test() {
  let source = "- a\n- b\n- c"
  yamleam.parse_raw(source)
  |> should.equal(
    Ok(YamlList([YamlString("a"), YamlString("b"), YamlString("c")])),
  )
}

pub fn sequence_in_mapping_test() {
  let source = "items:\n  - red\n  - green\n  - blue"
  yamleam.parse_raw(source)
  |> should.equal(
    Ok(
      YamlMap([
        #(
          "items",
          YamlList([
            YamlString("red"),
            YamlString("green"),
            YamlString("blue"),
          ]),
        ),
      ]),
    ),
  )
}

pub fn dash_with_inline_mapping_test() {
  let source = "- id: s1\n  title: First\n- id: s2\n  title: Second"
  yamleam.parse_raw(source)
  |> should.equal(
    Ok(
      YamlList([
        YamlMap([#("id", YamlString("s1")), #("title", YamlString("First"))]),
        YamlMap([#("id", YamlString("s2")), #("title", YamlString("Second"))]),
      ]),
    ),
  )
}

pub fn nested_dash_with_inline_mapping_test() {
  let source =
    "sections:
  - id: s1
    title: First Section
    questions:
      - id: q1
        text: Is this a test?
      - id: q2
        text: How many?
  - id: s2
    title: Second"
  yamleam.parse_raw(source)
  |> should.equal(
    Ok(
      YamlMap([
        #(
          "sections",
          YamlList([
            YamlMap([
              #("id", YamlString("s1")),
              #("title", YamlString("First Section")),
              #(
                "questions",
                YamlList([
                  YamlMap([
                    #("id", YamlString("q1")),
                    #("text", YamlString("Is this a test?")),
                  ]),
                  YamlMap([
                    #("id", YamlString("q2")),
                    #("text", YamlString("How many?")),
                  ]),
                ]),
              ),
            ]),
            YamlMap([
              #("id", YamlString("s2")),
              #("title", YamlString("Second")),
            ]),
          ]),
        ),
      ]),
    ),
  )
}

pub fn mapping_with_quoted_value_test() {
  let source = "msg: \"hello world\""
  yamleam.parse_raw(source)
  |> should.equal(Ok(YamlMap([#("msg", YamlString("hello world"))])))
}

pub fn quoted_value_with_special_chars_test() {
  let source = "msg: \"value: with colon\""
  yamleam.parse_raw(source)
  |> should.equal(Ok(YamlMap([#("msg", YamlString("value: with colon"))])))
}

pub fn null_value_explicit_test() {
  let source = "name: ~"
  yamleam.parse_raw(source) |> should.equal(Ok(YamlMap([#("name", YamlNull)])))
}

pub fn float_value_test() {
  let source = "pi: 3.14"
  yamleam.parse_raw(source)
  |> should.equal(Ok(YamlMap([#("pi", YamlFloat(3.14))])))
}

pub fn comment_only_lines_skipped_test() {
  let source =
    "# leading comment
name: Alice
# middle comment
age: 30
# trailing comment"
  yamleam.parse_raw(source)
  |> should.equal(
    Ok(YamlMap([#("name", YamlString("Alice")), #("age", YamlInt(30))])),
  )
}

pub fn inline_comment_stripped_test() {
  let source = "name: Alice # the user"
  yamleam.parse_raw(source)
  |> should.equal(Ok(YamlMap([#("name", YamlString("Alice"))])))
}

pub fn empty_mapping_value_test() {
  // `key:` with no value is YamlNull
  let source = "name:"
  yamleam.parse_raw(source) |> should.equal(Ok(YamlMap([#("name", YamlNull)])))
}

pub fn duplicate_top_level_key_rejected_test() {
  // YAML 1.2 spec requires unique mapping keys.
  let source = "role: admin\nrole: user"
  case yamleam.parse_raw(source) {
    Error(_) -> Nil
    Ok(_) -> should.fail()
  }
}

pub fn duplicate_nested_key_rejected_test() {
  let source = "outer:\n  key: a\n  key: b"
  case yamleam.parse_raw(source) {
    Error(_) -> Nil
    Ok(_) -> should.fail()
  }
}

pub fn duplicate_inline_mapping_key_rejected_test() {
  // The dash + inline mapping case must also reject duplicates.
  let source = "- id: s1\n  id: s2"
  case yamleam.parse_raw(source) {
    Error(_) -> Nil
    Ok(_) -> should.fail()
  }
}

pub fn duplicate_keys_in_separate_mappings_are_fine_test() {
  // Two sequence items each with their own `id` are NOT duplicates —
  // they live in different mappings.
  let source = "- id: s1\n  name: first\n- id: s2\n  name: second"
  case yamleam.parse_raw(source) {
    Ok(_) -> Nil
    Error(_) -> should.fail()
  }
}

// ── v0.2: literal block scalars ───────────────────────────────────────────

pub fn literal_block_scalar_basic_test() {
  let source =
    "script: |
  echo hello
  echo world"
  yamleam.parse_raw(source)
  |> should.equal(
    Ok(YamlMap([#("script", YamlString("echo hello\necho world\n"))])),
  )
}

pub fn literal_block_scalar_strip_chomping_test() {
  let source =
    "script: |-
  echo hello
  echo world"
  yamleam.parse_raw(source)
  |> should.equal(
    Ok(YamlMap([#("script", YamlString("echo hello\necho world"))])),
  )
}

pub fn literal_block_scalar_keep_chomping_test() {
  let source =
    "script: |+
  echo hello


next: value"
  // Keep preserves the trailing blank lines as newlines
  yamleam.parse_raw(source)
  |> should.equal(
    Ok(
      YamlMap([
        #("script", YamlString("echo hello\n\n\n")),
        #("next", YamlString("value")),
      ]),
    ),
  )
}

pub fn literal_block_scalar_with_blank_lines_inside_test() {
  let source =
    "msg: |
  first paragraph

  second paragraph"
  yamleam.parse_raw(source)
  |> should.equal(
    Ok(
      YamlMap([
        #("msg", YamlString("first paragraph\n\nsecond paragraph\n")),
      ]),
    ),
  )
}

pub fn literal_block_scalar_in_sequence_item_test() {
  let source =
    "- name: step1
  run: |
    echo first
    echo second
- name: step2
  run: |
    echo third"
  yamleam.parse_raw(source)
  |> should.equal(
    Ok(
      YamlList([
        YamlMap([
          #("name", YamlString("step1")),
          #("run", YamlString("echo first\necho second\n")),
        ]),
        YamlMap([
          #("name", YamlString("step2")),
          #("run", YamlString("echo third\n")),
        ]),
      ]),
    ),
  )
}

pub fn literal_block_scalar_followed_by_sibling_key_test() {
  let source =
    "before: 1
script: |
  command line
after: 2"
  yamleam.parse_raw(source)
  |> should.equal(
    Ok(
      YamlMap([
        #("before", YamlInt(1)),
        #("script", YamlString("command line\n")),
        #("after", YamlInt(2)),
      ]),
    ),
  )
}

pub fn literal_block_scalar_deeply_indented_test() {
  let source =
    "outer:
  inner:
    script: |
      one
      two
    after: done"
  yamleam.parse_raw(source)
  |> should.equal(
    Ok(
      YamlMap([
        #(
          "outer",
          YamlMap([
            #(
              "inner",
              YamlMap([
                #("script", YamlString("one\ntwo\n")),
                #("after", YamlString("done")),
              ]),
            ),
          ]),
        ),
      ]),
    ),
  )
}

pub fn literal_block_scalar_with_inline_comment_after_opener_test() {
  let source =
    "script: | # this script does things
  echo hi"
  yamleam.parse_raw(source)
  |> should.equal(Ok(YamlMap([#("script", YamlString("echo hi\n"))])))
}
