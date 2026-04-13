import gleam/dynamic/decode
import gleam/list
import gleeunit/should
import yamleam

pub type Config {
  Config(name: String, port: Int, debug: Bool, tags: List(String))
}

pub fn decode_simple_config_test() {
  let source =
    "name: my-service
port: 8080
debug: true
tags:
  - alpha
  - beta
  - gamma"

  let decoder = {
    use name <- decode.field("name", decode.string)
    use port <- decode.field("port", decode.int)
    use debug <- decode.field("debug", decode.bool)
    use tags <- decode.field("tags", decode.list(decode.string))
    decode.success(Config(name:, port:, debug:, tags:))
  }

  yamleam.parse(source, decoder)
  |> should.equal(
    Ok(
      Config(name: "my-service", port: 8080, debug: True, tags: [
        "alpha",
        "beta",
        "gamma",
      ]),
    ),
  )
}

pub type Question {
  Question(id: String, text: String)
}

pub type Section {
  Section(id: String, title: String, questions: List(Question))
}

pub type Ruleset {
  Ruleset(title: String, sections: List(Section))
}

pub fn decode_nested_ruleset_test() {
  let source =
    "title: Example Ruleset
sections:
  - id: s1
    title: Section One
    questions:
      - id: q1
        text: First question
      - id: q2
        text: Second question
  - id: s2
    title: Section Two
    questions:
      - id: q3
        text: Third question"

  let question_decoder = {
    use id <- decode.field("id", decode.string)
    use text <- decode.field("text", decode.string)
    decode.success(Question(id:, text:))
  }

  let section_decoder = {
    use id <- decode.field("id", decode.string)
    use title <- decode.field("title", decode.string)
    use questions <- decode.field("questions", decode.list(question_decoder))
    decode.success(Section(id:, title:, questions:))
  }

  let ruleset_decoder = {
    use title <- decode.field("title", decode.string)
    use sections <- decode.field("sections", decode.list(section_decoder))
    decode.success(Ruleset(title:, sections:))
  }

  let result = yamleam.parse(source, ruleset_decoder)

  case result {
    Ok(ruleset) -> {
      ruleset.title |> should.equal("Example Ruleset")
      list.length(ruleset.sections) |> should.equal(2)
      let assert [s1, s2] = ruleset.sections
      s1.id |> should.equal("s1")
      s1.title |> should.equal("Section One")
      list.length(s1.questions) |> should.equal(2)
      let assert [q1, q2] = s1.questions
      q1.id |> should.equal("q1")
      q1.text |> should.equal("First question")
      q2.id |> should.equal("q2")
      q2.text |> should.equal("Second question")
      s2.id |> should.equal("s2")
      list.length(s2.questions) |> should.equal(1)
    }
    Error(e) -> {
      let _ = e
      should.fail()
    }
  }
}

pub fn decode_int_when_str_expected_fails_test() {
  let source = "name: 42"
  let decoder = {
    use name <- decode.field("name", decode.string)
    decode.success(name)
  }
  let result = yamleam.parse(source, decoder)
  case result {
    Ok(_) -> should.fail()
    Error(_) -> Nil
  }
}
