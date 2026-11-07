//// Probe: verify mork parses chat markdown correctly on this toolchain
//// (gleam 1.19 / OTP 27) and pin the hostile-AST shapes a markdown
//// renderer will have to neutralize — raw HTML blocks, inline HTML, and
//// javascript: link destinations. Groundwork for nexus/ui/markdown.

import gleam/list
import gleam/string
import gleeunit/should
import mork
import mork/document.{type Block, Heading, HtmlBlock, Paragraph}

fn parse(md: String) -> List(Block) {
  mork.configure()
  |> mork.tables(True)
  |> mork.parse_with_options(md)
  |> fn(doc: document.Document) { doc.blocks }
}

/// Blank-line separators between blocks — the future renderer maps these
/// to element.none(); content assertions filter them out.
fn content(md: String) -> List(Block) {
  parse(md)
  |> list.filter(fn(b) {
    case b {
      document.Newline | document.Empty -> False
      _ -> True
    }
  })
}

pub fn parses_realistic_reply_test() {
  let blocks =
    content(
      "## Plan\n\nRun the **migrations** with `gleam run`:\n\n```sh\ngleam run -m squirrel\n```\n\n| step | status |\n|------|--------|\n| 1    | done   |\n\n- item one\n- item *two*\n",
    )

  // heading, paragraph, fenced code, table, bullet list — all distinct.
  should.be_true(list.length(blocks) >= 5)
  let assert [Heading(2, _, _, _), Paragraph(_, inlines), ..] = blocks
  // bold survived as a typed inline, not raw text.
  should.be_true(
    list.any(inlines, fn(i) {
      case i {
        document.Strong(_) -> True
        _ -> False
      }
    }),
  )
}

pub fn hostile_raw_html_block_is_its_own_node_test() {
  // A fenced-looking HTML block: mork keeps it verbatim in an HtmlBlock.
  let assert [HtmlBlock(raw), ..] =
    content("<script>alert(\"pwned\")</script>\n")
  string.contains(raw, "<script>") |> should.be_true
}

pub fn hostile_inline_html_is_its_own_node_test() {
  // Inline HTML inside a paragraph: mork flags it as RawHtml (or InlineHtml
  // for paired tags) — either way a distinct node the renderer must drop
  // or escape rather than emit.
  let blocks = content("hello <img src=x onerror=alert(1)> world\n")
  let assert [Paragraph(_, inlines), ..] = blocks
  should.be_true(
    list.any(inlines, fn(i) {
      case i {
        document.RawHtml(_) | document.InlineHtml(..) -> True
        _ -> False
      }
    }),
  )
}

pub fn hostile_javascript_link_keeps_scheme_in_ast_test() {
  // The AST preserves the javascript: destination verbatim — the renderer
  // must scheme-filter hrefs itself; nothing upstream does it.
  let blocks = content("[click me](javascript:alert(1))\n")
  let assert [Paragraph(_, inlines), ..] = blocks
  let assert [document.FullLink(_, data), ..] =
    list.filter(inlines, fn(i) {
      case i {
        document.FullLink(..) -> True
        _ -> False
      }
    })
  let assert document.Absolute(href) = data.dest
  should.equal(href, "javascript:alert(1)")
}

pub fn gfm_tables_require_opt_in_test() {
  // Defaults keep tables off (raw pipes); tables(True) yields a Table block.
  let md = "| a | b |\n|---|---|\n| 1 | 2 |\n"
  let default_blocks =
    mork.configure() |> mork.parse_with_options(md) |> fn(d) { d.blocks }
  let assert [Paragraph(..), ..] = default_blocks

  let assert [document.Table(..), ..] = parse(md)
}
