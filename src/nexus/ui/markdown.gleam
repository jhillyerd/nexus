//// Markdown rendering for committed assistant chat turns: mork AST →
//// Lustre elements. This module is part of the UI's hostile-text
//// contract (see the module doc in `nexus/ui.gleam`): model output is
//// never trusted, so there is no `unsafe_raw_html` here and there never
//// will be. Everything below renders into escaped text nodes or
//// fixed-tag Lustre elements.
////
//// Neutralization rules (pinned by `test/markdown_test.gleam`, which
//// feeds `<script>` and `javascript:` payloads):
////
//// - Raw HTML never becomes markup. `HtmlBlock` / `RawHtml` /
////   `InlineHtml` render as inert escaped text, so a model cannot inject
////   tags through the markdown path.
//// - Link destinations are scheme-filtered. Only `http:`, `https:`,
////   `mailto:`, in-page anchors, and relative paths become `href`s;
////   anything else (`javascript:`, `data:`, …) renders the link text
////   without an anchor.
//// - Images render as links, not `<img>` — nexus serves only
////   self-hosted assets, and a model-supplied src would be an external
////   fetch (and a tracking pixel) the moment it rendered.
//// - Footnote definitions are dropped; references render as `^n`.
////
//// Only committed assistant lines go through here: user turns, tool
//// cards, and reasoning blocks stay plain text, and the live streaming
//// bubble renders plain pre-wrap text until the turn commits (a
//// half-streamed construct must never look committed).

import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/attribute
import lustre/element.{type Element, fragment, text}
import lustre/element/html
import mork
import mork/document

/// Parse markdown and render it as a list of Lustre elements. GFM tables
/// are enabled (model replies use them constantly); footnotes,
/// tasklists, autolinks, and emoji shortcodes stay off.
pub fn render(text: String) -> List(Element(msg)) {
  mork.configure()
  |> mork.tables(True)
  |> mork.parse_with_options(text)
  |> fn(doc: document.Document) { render_blocks(doc, doc.blocks) }
}

fn render_blocks(doc: document.Document, blocks: List(document.Block)) {
  // Newline/Empty are blank-line separators between blocks; the block
  // elements carry their own margins, so they drop out entirely.
  list.filter_map(blocks, render_block(doc, _))
}

fn render_block(
  doc: document.Document,
  block: document.Block,
) -> Result(Element(msg), Nil) {
  case block {
    document.Newline | document.Empty -> Error(Nil)
    document.Heading(level, _id, _raw, inlines) ->
      Ok(case level {
        1 -> html.h1([], render_inlines(doc, inlines))
        2 -> html.h2([], render_inlines(doc, inlines))
        3 -> html.h3([], render_inlines(doc, inlines))
        4 -> html.h4([], render_inlines(doc, inlines))
        5 -> html.h5([], render_inlines(doc, inlines))
        _ -> html.h6([], render_inlines(doc, inlines))
      })
    document.Paragraph(_raw, inlines) ->
      Ok(html.p([], render_inlines(doc, inlines)))
    document.Code(_lang, code) ->
      // The language rides in nothing for now; syntax highlighting can
      // key off it later without changing this shape.
      Ok(html.pre([], [html.code([], [text(code)])]))
    document.BlockQuote(blocks) ->
      Ok(html.blockquote([], render_blocks(doc, blocks)))
    document.BulletList(pack, items) ->
      Ok(html.ul([], list.map(items, render_item(doc, pack, _))))
    document.OrderedList(pack, items, start) ->
      Ok(html.ol(
        case start {
          Some(n) -> [attribute.attribute("start", int.to_string(n))]
          None -> []
        },
        list.map(items, render_item(doc, pack, _)),
      ))
    document.Table(header, rows) -> Ok(render_table(doc, header, rows))
    document.ThematicBreak -> Ok(html.hr([]))
    // Hostile: an HTML block is model output, not formatting. Render the
    // source as inert escaped text so the user sees exactly what the
    // model sent and the browser parses none of it.
    document.HtmlBlock(raw) -> Ok(html.p([], [text(raw)]))
  }
}

/// Tight list items render their paragraphs bare (CommonMark); loose
/// items keep `<p>` wrappers. `render_blocks` already drops separators.
fn render_item(
  doc: document.Document,
  pack: document.ListPack,
  item: document.ListItem,
) -> Element(msg) {
  let children = case pack {
    document.Tight ->
      list.flat_map(item.blocks, fn(block) {
        case block {
          document.Paragraph(_, inlines) -> render_inlines(doc, inlines)
          _ -> render_blocks(doc, [block])
        }
      })
    document.Loose -> render_blocks(doc, item.blocks)
  }
  html.li([], children)
}

fn render_table(
  doc: document.Document,
  header: List(document.THead),
  rows: List(List(document.Cell)),
) -> Element(msg) {
  let aligns = list.map(header, fn(head) { head.align })
  let thead =
    html.thead([], [
      html.tr(
        [],
        list.map(header, fn(head) {
          html.th(table_align(head.align), render_inlines(doc, head.inlines))
        }),
      ),
    ])
  let tbody =
    html.tbody(
      [],
      list.map(rows, fn(cells) {
        html.tr(
          [],
          list.map2(cells, aligns, fn(cell, align) {
            html.td(table_align(align), render_inlines(doc, cell.inlines))
          }),
        )
      }),
    )
  html.table([], [thead, tbody])
}

fn table_align(align: document.Alignment) -> List(attribute.Attribute(msg)) {
  case align {
    document.Left -> [attribute.attribute("style", "text-align: left")]
    document.Center -> [attribute.attribute("style", "text-align: center")]
    document.Right -> [attribute.attribute("style", "text-align: right")]
  }
}

fn render_inlines(doc: document.Document, inlines: List(document.Inline)) {
  list.map(inlines, render_inline(doc, _))
}

fn render_inline(
  doc: document.Document,
  inline: document.Inline,
) -> Element(msg) {
  case inline {
    document.Text(t) -> text(t)
    document.SoftBreak -> text("\n")
    document.HardBreak -> html.br([])
    document.CodeSpan(code) -> html.code([], [text(code)])
    document.Emphasis(inner) -> html.em([], render_inlines(doc, inner))
    document.Strong(inner) -> html.strong([], render_inlines(doc, inner))
    document.Strikethrough(inner) -> html.del([], render_inlines(doc, inner))
    document.Highlight(inner) -> html.mark([], render_inlines(doc, inner))
    document.Autolink(dest, label) ->
      case scheme_href(dest) {
        Some(href) ->
          html.a([attribute.attribute("href", href)], [
            text(option.unwrap(label, dest)),
          ])
        None -> text(option.unwrap(label, dest))
      }
    document.EmailAutolink(mail) ->
      safe_link(document.Absolute("mailto:" <> mail), mail)
    document.FullLink(inner, data) ->
      safe_link_children(data.dest, render_inlines(doc, inner), data.title)
    document.RefLink(inner, label) ->
      case dict.get(doc.links, label) {
        Ok(data) ->
          safe_link_children(data.dest, render_inlines(doc, inner), data.title)
        // Unresolved reference. Probed: mork 1.12.3 never emits RefLink
        // for an undefined label — `[docs][missing]` stays literal Text
        // nodes — so this branch is defensive; the link text still
        // renders, as plain inline content.
        Error(_) -> fragment(render_inlines(doc, inner))
      }
    // Images render as links to their source (see module doc): the alt
    // text labels the link, so nothing external loads by rendering.
    document.FullImage(inner, data) -> image_link(data.dest, alt_text(inner))
    document.RefImage(inner, label) ->
      case dict.get(doc.links, label) {
        Ok(data) -> image_link(data.dest, alt_text(inner))
        Error(_) -> fragment(render_inlines(doc, inner))
      }
    // Hostile inline HTML: same rule as HtmlBlock — the tag and its
    // attributes appear as text, its children render as markdown. Paired
    // tags keep their closing tag so the inert preview shows the complete
    // source; childless tags (void elements) get none. Probed: mork 1.12.3
    // mostly emits paired tags as separate RawHtml nodes anyway, so this
    // branch is defensive — but it must stay complete if it ever runs.
    document.InlineHtml(tag, attrs, children) -> {
      let closing = case children {
        [] -> []
        _ -> [text("</" <> tag <> ">")]
      }
      html.span([], [
        text(tag <> string.concat(dict.to_list(attrs) |> list.map(inline_attr))),
        ..list.append(render_inlines(doc, children), closing)
      ])
    }
    document.RawHtml(raw) -> text(raw)
    // Footnote definitions are dropped entirely; a reference keeps its
    // marker so the numbering the model emitted stays visible.
    document.Footnote(num, _label) -> html.sup([], [text(int.to_string(num))])
    document.InlineFootnote(_num, inner) -> fragment(render_inlines(doc, inner))
    // Unreachable with the options render() passes (tasklists off,
    // delimiters resolved in the inline pass) — handled defensively so a
    // future options change cannot crash the log.
    document.Checkbox(checked) ->
      text(case checked {
        True -> "[x] "
        False -> "[ ] "
      })
    document.Delim(style, len, _open, _close) -> text(string.repeat(style, len))
  }
}

fn inline_attr(kv: #(String, String)) -> String {
  " " <> kv.0 <> "=\"" <> kv.1 <> "\""
}

fn alt_text(inlines: List(document.Inline)) -> String {
  inlines
  |> list.map(fn(inline) {
    case inline {
      document.Text(t) -> t
      document.CodeSpan(t) -> t
      document.Emphasis(inner)
      | document.Strong(inner)
      | document.Strikethrough(inner)
      | document.Highlight(inner) -> alt_text(inner)
      document.SoftBreak | document.HardBreak -> " "
      _ -> ""
    }
  })
  |> string.concat
}

/// An image's link: labelled by its alt text, falling back to the source
/// when the model emitted no alt.
fn image_link(dest: document.Destination, alt: String) -> Element(msg) {
  let src = destination_string(dest)
  let label = case alt {
    "" -> src
    alt -> alt
  }
  case safe_href(dest) {
    Some(href) -> html.a([attribute.attribute("href", href)], [text(label)])
    None -> text(label)
  }
}

/// A link whose destination passed the scheme filter.
fn safe_link(dest: document.Destination, label: String) -> Element(msg) {
  case safe_href(dest) {
    Some(href) -> html.a([attribute.attribute("href", href)], [text(label)])
    None -> text(label)
  }
}

fn safe_link_children(
  dest: document.Destination,
  children: List(Element(msg)),
  title: Option(String),
) -> Element(msg) {
  case safe_href(dest) {
    Some(href) ->
      html.a(
        case title {
          Some(t) -> [
            attribute.attribute("href", href),
            attribute.attribute("title", t),
          ]
          None -> [attribute.attribute("href", href)]
        },
        children,
      )
    // Hostile scheme: render the link text with no anchor at all.
    None -> fragment(children)
  }
}

/// Destination-string for image-src labels. Scheme filtering happens in
/// `safe_href` — this only unwraps the variant.
fn destination_string(dest: document.Destination) -> String {
  case dest {
    document.Absolute(uri) -> uri
    document.Relative(uri) -> uri
    document.Anchor(anchor) -> "#" <> anchor
  }
}

/// The href allowlist, on mork's typed destination. Anchors and relative
/// paths are safe by construction (the browser resolves them against our
/// own origin); absolute destinations must carry an allowed scheme. The
/// allowlist — not a blocklist — is what keeps `javascript:`, `data:`,
/// and future exotic schemes out.
fn safe_href(dest: document.Destination) -> Option(String) {
  case contains_control_char(destination_string(dest)) {
    True -> None
    False ->
      case dest {
        document.Anchor(anchor) -> Some("#" <> anchor)
        document.Relative(uri) -> Some(uri)
        document.Absolute(uri) -> scheme_href(uri)
      }
  }
}

/// Refuse any destination carrying an ASCII control character (C0 or
/// DEL). URL parsers strip tab/LF/CR before scheme detection, so a
/// control-character-obfuscated scheme could otherwise smuggle past the
/// prefix check — and mork hands such strings through verbatim (probed:
/// `[x](<jav\tascript:alert(1)>)` parses to
/// `Absolute("jav\tascript:alert(1)")`). The prefix allowlist already
/// refuses every such obfuscation today — an obfuscated scheme cannot
/// also match `http:` — but that refusal is forensic, not structural;
/// dropping the whole class keeps it structural. Legit links never
/// contain control characters.
fn contains_control_char(s: String) -> Bool {
  s
  |> string.to_utf_codepoints
  |> list.any(fn(cp) {
    let code = string.utf_codepoint_to_int(cp)
    code < 0x20 || code == 0x7f
  })
}

/// The allowlist for string URIs (autolinks): lowercase-match the scheme
/// prefix so `JaVaScRiPt:` tricks get caught by the refusal, not the case.
fn scheme_href(uri: String) -> Option(String) {
  let lower = string.lowercase(uri)
  case
    string.starts_with(lower, "http:")
    || string.starts_with(lower, "https:")
    || string.starts_with(lower, "mailto:")
  {
    True -> Some(uri)
    False -> None
  }
}
