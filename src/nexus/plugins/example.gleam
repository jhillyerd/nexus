//// The example plugin (plugin-api plan Phase 1): the reference
//// implementation and test vehicle for the tier-1 SDK. Compiled into
//// the release and listed by config (`NEXUS_PLUGINS=example`), which
//// gates its AVAILABILITY — never default membership (a plugin tool
//// enters a thread only via a bot template or an explicit create
//// toolset, like every provider tool).
////
//// One deliberately boring tool (`echo`) so the reference shows the
//// whole shape without burying it in behaviour: a `plugin.Plugin` is
//// just a name, ToolDefs (unqualified names + raw schema text), and a
//// call fn from (tool, arguments) to plain-text result. The SDK builds
//// the actor; nothing here touches processes or the catalog.

import gleam/dynamic/decode
import gleam/json
import gleam/option.{None}
import nexus/tool_provider

pub fn plugin() -> tool_provider.Plugin {
  tool_provider.Plugin(
    name: "example",
    tools: [
      tool_provider.ToolDef(
        name: "echo",
        description: "Echo the `text` argument back, verbatim. The example"
          <> " plugin's reference tool: it does nothing else, so the"
          <> " plugin-api contract can be exercised end to end.",
        parameters_json: "{\"type\":\"object\",\"properties\":{\"text\":"
          <> "{\"type\":\"string\",\"description\":\"Text to return"
          <> " unchanged\"}},\"required\":[\"text\"],"
          <> "\"additionalProperties\":false}",
      ),
    ],
    call: run,
    // No override: the config default (`plugin_timeout_ms`) governs.
    timeout_ms: None,
  )
}

fn run(tool: String, arguments: String) -> Result(String, String) {
  case tool {
    "echo" -> {
      let decoder = {
        use text <- decode.field("text", decode.string)
        decode.success(text)
      }
      case json.parse(arguments, decoder) {
        Ok(text) -> Ok(text)
        Error(_) -> Error("example__echo requires a string field 'text'")
      }
    }
    // Unreachable through the catalog (the spec executor is bound to a
    // validated ToolDef); honest refusal if a caller bypasses it.
    other -> Error("unknown plugin tool: " <> other)
  }
}
