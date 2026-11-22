//// Pure-Gleam HTML-to-Markdown converter over `htmgrrrl` (`htmerl` 0.2.1).
////
//// Single-pass SAX state machine: streams tokens without building a full DOM,
//// drops non-content subtrees (`script`, `style`, `svg`, form controls, and
//// `nav`/`footer`/`aside` with an empty-body safety fallback), preserves
//// `<pre>` whitespace verbatim (`htmgrrrl` invokes `htmerl` with
//// `{preserve_ws, true}`), resolves relative links via `nexus/net`, and
//// normalizes whitespace outside `<pre>` into compact Markdown suitable for
//// LLM tool results.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import htmgrrrl.{type Attribute, type SaxEvent}
import nexus/net

/// Result of converting an HTML document.
pub type Converted {
  Converted(title: Option(String), markdown: String)
}

/// Maximum `img[alt]` length kept inline (longer descriptions are usually
/// noisy captions or base64/SEO spam).
const max_img_alt_chars = 120

/// Convert HTML into compact Markdown and extract the first `<title>`, if any.
/// Relative link targets resolve against `base_url` (when non-empty).
pub fn convert(html: String, base_url: String) -> Converted {
  let html = case string.starts_with(html, "\u{FEFF}") {
    True -> string.drop_start(html, 1)
    False -> html
  }
  let first = run_pass(html, base_url, True)
  case first.dropped_chrome && string.trim(first.markdown) == "" {
    True -> {
      let fallback = run_pass(html, base_url, False)
      Converted(
        title: option.or(first.title, fallback.title),
        markdown: fallback.markdown,
      )
    }
    False -> Converted(title: first.title, markdown: first.markdown)
  }
}

type PassOutcome {
  PassOutcome(title: Option(String), markdown: String, dropped_chrome: Bool)
}

fn run_pass(html: String, base_url: String, drop_chrome: Bool) -> PassOutcome {
  let initial =
    State(
      base_url: base_url,
      drop_chrome: drop_chrome,
      dropped_chrome: False,
      drop_depth: 0,
      head_depth: 0,
      title_depth: 0,
      title_chunks: [],
      title: None,
      pre_depth: 0,
      pre_lang: None,
      pre_chunks: [],
      blockquote_depth: 0,
      lists: [],
      table_depth: 0,
      table_rows: [],
      current_row: None,
      frames: [],
      doc: empty_doc(),
    )
  case
    htmgrrrl.sax(html, initial, fn(state, _line, event) { handle(state, event) })
  {
    Ok(final) -> {
      let final = flush_open_frames(final)
      let title = case final.title {
        Some(t) -> Some(t)
        None -> finalize_title(final.title_chunks)
      }
      PassOutcome(
        title: title,
        markdown: finalize_doc(final.doc),
        dropped_chrome: final.dropped_chrome,
      )
    }
    Error(Nil) -> PassOutcome(title: None, markdown: "", dropped_chrome: False)
  }
}

// ---------------------------------------------------------------------------
// State model
// ---------------------------------------------------------------------------

type Break {
  BreakNone
  BreakLine
  BreakParagraph
}

type ListKind {
  Unordered
  Ordered(next_index: Int)
}

type DocBuf {
  DocBuf(
    chunks: List(String),
    pending_break: Break,
    pending_space: Bool,
    at_line_start: Bool,
    just_started_li: Bool,
    has_content: Bool,
  )
}

type InlineKind {
  Heading(level: Int)
  Link(href: Option(String), fallback_alt: Option(String))
  Strong
  Em
  InlineCode
  TableCell(is_header: Bool)
}

type InlineFrame {
  InlineFrame(
    kind: InlineKind,
    chunks: List(String),
    pending_space: Bool,
    leading_space: Bool,
    trailing_space: Bool,
    has_content: Bool,
  )
}

type TableCellData {
  TableCellData(is_header: Bool, text: String)
}

type State {
  State(
    base_url: String,
    drop_chrome: Bool,
    dropped_chrome: Bool,
    drop_depth: Int,
    head_depth: Int,
    title_depth: Int,
    title_chunks: List(String),
    title: Option(String),
    pre_depth: Int,
    pre_lang: Option(String),
    pre_chunks: List(String),
    blockquote_depth: Int,
    lists: List(ListKind),
    table_depth: Int,
    table_rows: List(List(TableCellData)),
    current_row: Option(List(TableCellData)),
    frames: List(InlineFrame),
    doc: DocBuf,
  )
}

fn empty_doc() -> DocBuf {
  DocBuf(
    chunks: [],
    pending_break: BreakNone,
    pending_space: False,
    at_line_start: True,
    just_started_li: False,
    has_content: False,
  )
}

fn empty_inline(kind: InlineKind) -> InlineFrame {
  InlineFrame(
    kind: kind,
    chunks: [],
    pending_space: False,
    leading_space: False,
    trailing_space: False,
    has_content: False,
  )
}

// ---------------------------------------------------------------------------
// SAX dispatch
// ---------------------------------------------------------------------------

fn handle(state: State, event: SaxEvent) -> State {
  case event {
    htmgrrrl.StartElement(_, local_name, _, attrs) ->
      handle_start(state, string.lowercase(local_name), attrs)
    htmgrrrl.EndElement(_, local_name, _) ->
      handle_end(state, string.lowercase(local_name))
    htmgrrrl.Characters(text) -> handle_text(state, text)
    htmgrrrl.IgnorableWhitespace(text) -> handle_text(state, text)
    _ -> state
  }
}

fn handle_start(state: State, tag: String, attrs: List(Attribute)) -> State {
  // Inside a dropped subtree: just track nesting depth so nothing leaks.
  case state.drop_depth > 0 {
    True -> State(..state, drop_depth: state.drop_depth + 1)
    False ->
      case state.head_depth > 0 {
        True -> handle_start_in_head(state, tag)
        False ->
          case state.title_depth > 0 {
            True -> State(..state, title_depth: state.title_depth + 1)
            False ->
              case state.pre_depth > 0 {
                True -> handle_start_in_pre(state, tag, attrs)
                False -> handle_start_body(state, tag, attrs)
              }
          }
      }
  }
}

fn handle_start_in_head(state: State, tag: String) -> State {
  case tag {
    "head" -> State(..state, head_depth: state.head_depth + 1)
    "title" -> State(..state, title_depth: state.title_depth + 1)
    _ ->
      case state.title_depth > 0 {
        True -> State(..state, title_depth: state.title_depth + 1)
        False -> state
      }
  }
}

fn handle_start_in_pre(
  state: State,
  tag: String,
  attrs: List(Attribute),
) -> State {
  case tag {
    "pre" -> State(..state, pre_depth: state.pre_depth + 1)
    "code" -> {
      let lang = case state.pre_lang {
        Some(_) -> state.pre_lang
        None -> extract_code_lang(attrs)
      }
      State(..state, pre_lang: lang)
    }
    "br" -> State(..state, pre_chunks: ["\n", ..state.pre_chunks])
    _ -> state
  }
}

fn handle_start_body(
  state: State,
  tag: String,
  attrs: List(Attribute),
) -> State {
  case is_always_dropped(tag) {
    True -> State(..state, drop_depth: 1)
    False ->
      case state.drop_chrome && is_chrome_tag(tag) {
        True -> State(..state, drop_depth: 1, dropped_chrome: True)
        False ->
          case tag {
            "head" -> State(..state, head_depth: 1)
            "title" -> State(..state, title_depth: 1)
            "pre" -> start_pre(state, attrs)
            "h1" -> start_heading(state, 1)
            "h2" -> start_heading(state, 2)
            "h3" -> start_heading(state, 3)
            "h4" -> start_heading(state, 4)
            "h5" -> start_heading(state, 5)
            "h6" -> start_heading(state, 6)
            "blockquote" -> start_blockquote(state)
            "ul" -> start_list(state, Unordered)
            "ol" -> start_list(state, Ordered(parse_ol_start(attrs)))
            "li" -> start_li(state)
            "br" -> handle_br(state)
            "hr" -> handle_hr(state)
            "table" -> start_table(state)
            "tr" -> start_tr(state)
            "th" -> start_table_cell(state, True)
            "td" -> start_table_cell(state, False)
            "a" -> start_link(state, attrs)
            "strong" | "b" -> push_inline_frame(state, Strong)
            "em" | "i" -> push_inline_frame(state, Em)
            "code" -> push_inline_frame(state, InlineCode)
            "img" -> handle_img(state, attrs)
            "p" -> block_break(state, BreakParagraph)
            "div"
            | "section"
            | "article"
            | "main"
            | "header"
            | "footer"
            | "nav"
            | "aside"
            | "figure"
            | "figcaption"
            | "dl"
            | "dt"
            | "dd"
            | "address"
            | "details"
            | "summary" -> block_break(state, BreakParagraph)
            _ -> state
          }
      }
  }
}

fn handle_end(state: State, tag: String) -> State {
  case state.drop_depth > 0 {
    True -> State(..state, drop_depth: int.max(0, state.drop_depth - 1))
    False ->
      case state.head_depth > 0 {
        True -> handle_end_in_head(state, tag)
        False ->
          case state.title_depth > 0 {
            True -> handle_end_title(state)
            False ->
              case state.pre_depth > 0 {
                True -> handle_end_in_pre(state, tag)
                False -> handle_end_body(state, tag)
              }
          }
      }
  }
}

fn handle_end_in_head(state: State, tag: String) -> State {
  case tag {
    "head" -> State(..state, head_depth: int.max(0, state.head_depth - 1))
    _ ->
      case state.title_depth > 0 {
        True -> handle_end_title(state)
        False -> state
      }
  }
}

fn handle_end_title(state: State) -> State {
  let next_depth = state.title_depth - 1
  case next_depth == 0 {
    True -> {
      let title = case state.title {
        Some(existing) -> Some(existing)
        None -> finalize_title(state.title_chunks)
      }
      State(..state, title_depth: 0, title: title, title_chunks: [])
    }
    False -> State(..state, title_depth: next_depth)
  }
}

fn handle_end_in_pre(state: State, tag: String) -> State {
  case tag {
    "pre" -> {
      let next_depth = state.pre_depth - 1
      case next_depth == 0 {
        True -> finish_pre(state)
        False -> State(..state, pre_depth: next_depth)
      }
    }
    _ -> state
  }
}

fn handle_end_body(state: State, tag: String) -> State {
  case tag {
    "h1" -> end_heading(state, 1)
    "h2" -> end_heading(state, 2)
    "h3" -> end_heading(state, 3)
    "h4" -> end_heading(state, 4)
    "h5" -> end_heading(state, 5)
    "h6" -> end_heading(state, 6)
    "blockquote" -> end_blockquote(state)
    "ul" | "ol" -> end_list(state)
    "li" -> end_li(state)
    "table" -> end_table(state)
    "tr" -> end_tr(state)
    "th" -> end_table_cell(state, True)
    "td" -> end_table_cell(state, False)
    "a" -> end_link(state)
    "strong" | "b" -> end_emphasis(state, Strong, "**")
    "em" | "i" -> end_emphasis(state, Em, "*")
    "code" -> end_inline_code(state)
    "p"
    | "div"
    | "section"
    | "article"
    | "main"
    | "header"
    | "footer"
    | "nav"
    | "aside"
    | "figure"
    | "figcaption"
    | "dl"
    | "dt"
    | "dd"
    | "address"
    | "details"
    | "summary" -> block_break(state, BreakParagraph)
    _ -> state
  }
}

fn handle_text(state: State, text: String) -> State {
  case state.drop_depth > 0 {
    True -> state
    False ->
      case state.title_depth > 0 {
        True ->
          case state.title {
            Some(_) -> state
            None -> State(..state, title_chunks: [text, ..state.title_chunks])
          }
        False ->
          case state.head_depth > 0 {
            True -> state
            False ->
              case state.pre_depth > 0 {
                True -> State(..state, pre_chunks: [text, ..state.pre_chunks])
                False -> emit_normalized_text(state, text)
              }
          }
      }
  }
}

// ---------------------------------------------------------------------------
// Block elements
// ---------------------------------------------------------------------------

fn start_pre(state: State, attrs: List(Attribute)) -> State {
  case state.frames {
    // Inside a table cell or inline wrapper: fall back to normal spacing.
    [_, ..] -> block_break(state, BreakLine)
    [] ->
      State(
        ..state,
        pre_depth: 1,
        pre_lang: extract_code_lang(attrs),
        pre_chunks: [],
      )
  }
}

fn finish_pre(state: State) -> State {
  let raw =
    state.pre_chunks
    |> list.reverse
    |> string.concat
    |> string.replace("\r\n", "\n")
    |> string.replace("\r", "\n")
  // Strip at most one leading newline (common after `<pre><code>\n`) and
  // trailing newlines so the closing fence lands cleanly on its own line.
  let body =
    raw
    |> strip_one_leading_newline
    |> strip_trailing_newlines
  let next_state = State(..state, pre_depth: 0, pre_lang: None, pre_chunks: [])
  case string.trim(body) == "" {
    True -> next_state
    False -> {
      let fence = choose_fence(body)
      let opener = case state.pre_lang {
        Some(lang) -> fence <> lang
        None -> fence
      }
      let lines = [opener, ..list.append(string.split(body, "\n"), [fence])]
      let prefix = blockquote_prefix(next_state.blockquote_depth)
      let block =
        lines
        |> list.map(fn(line) {
          case prefix == "" {
            True -> line
            False ->
              case line == "" {
                True -> string.trim_end(prefix)
                False -> prefix <> line
              }
          }
        })
        |> string.join("\n")
      let doc =
        next_state.doc
        |> upgrade_doc_break(BreakParagraph)
        |> emit_raw_block(block, next_state.blockquote_depth)
        |> upgrade_doc_break(BreakParagraph)
      State(..next_state, doc: doc)
    }
  }
}

fn start_heading(state: State, level: Int) -> State {
  case state.frames {
    // Inside a link, table cell, or another heading: treat as separator only.
    [_, ..] -> mark_frame_space(state)
    [] -> State(..state, frames: [empty_inline(Heading(level)), ..state.frames])
  }
}

fn end_heading(state: State, level: Int) -> State {
  case state.frames {
    [InlineFrame(kind: Heading(l), ..) as frame, ..rest] if l == level -> {
      let text = collapse_inline_whitespace(frame_text(frame))
      let base = State(..state, frames: rest)
      case text {
        "" -> base
        _ -> {
          let hashes = string.repeat("#", level)
          let prefix = blockquote_prefix(base.blockquote_depth)
          let line = prefix <> hashes <> " " <> text
          let doc =
            base.doc
            |> upgrade_doc_break(BreakParagraph)
            |> emit_raw_block(line, base.blockquote_depth)
            |> upgrade_doc_break(BreakParagraph)
          State(..base, doc: doc)
        }
      }
    }
    _ -> state
  }
}

fn start_blockquote(state: State) -> State {
  case state.frames {
    [_, ..] -> mark_frame_space(state)
    [] ->
      State(
        ..state,
        blockquote_depth: state.blockquote_depth + 1,
        doc: upgrade_doc_break(state.doc, BreakParagraph),
      )
  }
}

fn end_blockquote(state: State) -> State {
  case state.frames {
    [_, ..] -> mark_frame_space(state)
    [] ->
      State(
        ..state,
        blockquote_depth: int.max(0, state.blockquote_depth - 1),
        doc: upgrade_doc_break(state.doc, BreakParagraph),
      )
  }
}

fn start_list(state: State, kind: ListKind) -> State {
  case state.frames {
    [_, ..] -> mark_frame_space(state)
    [] -> {
      let brk = case state.lists {
        [] -> BreakParagraph
        _ -> BreakLine
      }
      State(
        ..state,
        lists: [kind, ..state.lists],
        doc: upgrade_doc_break(state.doc, brk),
      )
    }
  }
}

fn end_list(state: State) -> State {
  case state.frames {
    [_, ..] -> mark_frame_space(state)
    [] -> {
      let rest = case state.lists {
        [_, ..tail] -> tail
        [] -> []
      }
      let brk = case rest {
        [] -> BreakParagraph
        _ -> BreakLine
      }
      State(..state, lists: rest, doc: upgrade_doc_break(state.doc, brk))
    }
  }
}

fn start_li(state: State) -> State {
  case state.frames {
    [_, ..] -> mark_frame_space(state)
    [] -> {
      let #(marker, lists) = case state.lists {
        [Unordered, ..rest] -> #("- ", [Unordered, ..rest])
        [Ordered(n), ..rest] -> #(int.to_string(n) <> ". ", [
          Ordered(n + 1),
          ..rest
        ])
        [] -> #("- ", [])
      }
      let depth = list.length(lists)
      let indent = string.repeat("  ", int.max(0, depth - 1))
      let doc =
        state.doc
        |> upgrade_doc_break(BreakLine)
        |> emit_list_marker(indent <> marker, state.blockquote_depth)
      State(..state, lists: lists, doc: doc)
    }
  }
}

fn end_li(state: State) -> State {
  case state.frames {
    [_, ..] -> mark_frame_space(state)
    [] -> {
      // Reset any trailing BreakParagraph from an inner `</p>` so sibling
      // list items stay compact (`- a\n- b`); `end_list` still upgrades to
      // BreakParagraph when the list itself closes.
      let doc =
        DocBuf(
          ..state.doc,
          pending_break: BreakLine,
          pending_space: False,
          just_started_li: False,
        )
      State(..state, doc: doc)
    }
  }
}

fn handle_br(state: State) -> State {
  case state.frames {
    [_, ..] -> mark_frame_space(state)
    [] -> {
      let doc = case state.doc.has_content && !state.doc.at_line_start {
        True ->
          DocBuf(
            ..state.doc,
            chunks: ["\n", ..state.doc.chunks],
            pending_break: BreakNone,
            pending_space: False,
            at_line_start: True,
            just_started_li: False,
          )
        False -> upgrade_doc_break(state.doc, BreakLine)
      }
      State(..state, doc: doc)
    }
  }
}

fn handle_hr(state: State) -> State {
  case state.frames {
    [_, ..] -> mark_frame_space(state)
    [] -> {
      let prefix = blockquote_prefix(state.blockquote_depth)
      let doc =
        state.doc
        |> upgrade_doc_break(BreakParagraph)
        |> emit_raw_block(prefix <> "---", state.blockquote_depth)
        |> upgrade_doc_break(BreakParagraph)
      State(..state, doc: doc)
    }
  }
}

fn block_break(state: State, kind: Break) -> State {
  case state.frames {
    [_, ..] -> mark_frame_space(state)
    [] ->
      case state.doc.just_started_li {
        // First `<p>` / `<div>` inside `<li>` stays on the bullet line.
        True -> State(..state, doc: DocBuf(..state.doc, just_started_li: False))
        False -> State(..state, doc: upgrade_doc_break(state.doc, kind))
      }
  }
}

// ---------------------------------------------------------------------------
// Tables (GFM with nested-table fallback)
// ---------------------------------------------------------------------------

fn start_table(state: State) -> State {
  case state.table_depth == 0 && state.frames == [] {
    True ->
      State(
        ..state,
        table_depth: 1,
        table_rows: [],
        current_row: None,
        doc: upgrade_doc_break(state.doc, BreakParagraph),
      )
    False ->
      // Nested table: increment depth and separate cell text with a space.
      State(..mark_frame_space(state), table_depth: state.table_depth + 1)
  }
}

fn end_table(state: State) -> State {
  case state.table_depth {
    0 -> state
    1 -> {
      // Defensively flush any unclosed cell frame, then any unclosed row.
      let state = flush_open_table_cell(state)
      let rows = case state.current_row {
        Some(cells) -> [list.reverse(cells), ..state.table_rows]
        None -> state.table_rows
      }
      let rows = list.reverse(rows)
      let rendered = render_table(rows, state.blockquote_depth)
      let next =
        State(..state, table_depth: 0, table_rows: [], current_row: None)
      case rendered {
        "" -> next
        block -> {
          let doc =
            next.doc
            |> upgrade_doc_break(BreakParagraph)
            |> emit_raw_block(block, next.blockquote_depth)
            |> upgrade_doc_break(BreakParagraph)
          State(..next, doc: doc)
        }
      }
    }
    depth -> State(..mark_frame_space(state), table_depth: depth - 1)
  }
}

fn start_tr(state: State) -> State {
  case state.table_depth == 1 {
    True -> {
      let state = flush_open_table_cell(state)
      let rows = case state.current_row {
        Some(cells) -> [list.reverse(cells), ..state.table_rows]
        None -> state.table_rows
      }
      State(..state, table_rows: rows, current_row: Some([]))
    }
    False -> mark_frame_space(state)
  }
}

fn end_tr(state: State) -> State {
  case state.table_depth == 1 {
    True -> {
      let state = flush_open_table_cell(state)
      case state.current_row {
        Some(cells) ->
          State(
            ..state,
            table_rows: [list.reverse(cells), ..state.table_rows],
            current_row: None,
          )
        None -> state
      }
    }
    False -> mark_frame_space(state)
  }
}

/// Defensively close any open `TableCell` frame (and any inline wrappers
/// nested inside it) so an unclosed `<td>`/`<th>` can never trap later rows
/// or body text.
fn flush_open_table_cell(state: State) -> State {
  case inside_table_cell(state.frames) {
    False -> state
    True ->
      case state.frames {
        [] -> state
        [InlineFrame(kind: TableCell(is_header), ..), ..] ->
          end_table_cell(state, is_header)
        _ -> flush_open_table_cell(close_top_frame(state))
      }
  }
}

/// Flush any dangling inline/heading/cell frames at document end so truncated
/// or malformed HTML never silently drops buffered text.
fn flush_open_frames(state: State) -> State {
  case state.frames {
    [] ->
      case state.table_depth > 0 {
        True -> flush_open_frames(end_table(State(..state, table_depth: 1)))
        False -> state
      }
    _ -> flush_open_frames(close_top_frame(state))
  }
}

fn close_top_frame(state: State) -> State {
  case state.frames {
    [] -> state
    [InlineFrame(kind: Heading(level), ..), ..] -> end_heading(state, level)
    [InlineFrame(kind: Link(_, _), ..), ..] -> end_link(state)
    [InlineFrame(kind: Strong, ..), ..] -> end_emphasis(state, Strong, "**")
    [InlineFrame(kind: Em, ..), ..] -> end_emphasis(state, Em, "*")
    [InlineFrame(kind: InlineCode, ..), ..] -> end_inline_code(state)
    [InlineFrame(kind: TableCell(is_header), ..), ..] ->
      end_table_cell(state, is_header)
  }
}

fn start_table_cell(state: State, is_header: Bool) -> State {
  case state.table_depth == 1 && !inside_table_cell(state.frames) {
    True -> {
      let current_row = case state.current_row {
        Some(cells) -> Some(cells)
        None -> Some([])
      }
      State(..state, current_row: current_row, frames: [
        empty_inline(TableCell(is_header)),
        ..state.frames
      ])
    }
    False -> mark_frame_space(state)
  }
}

fn end_table_cell(state: State, is_header: Bool) -> State {
  case state.frames {
    [InlineFrame(kind: TableCell(h), ..) as frame, ..rest] if h == is_header -> {
      let text = collapse_inline_whitespace(frame_text(frame))
      let cell = TableCellData(is_header: is_header, text: text)
      let next_row = case state.current_row {
        Some(cells) -> Some([cell, ..cells])
        None -> Some([cell])
      }
      State(..state, current_row: next_row, frames: rest)
    }
    _ -> state
  }
}

fn inside_table_cell(frames: List(InlineFrame)) -> Bool {
  list.any(frames, fn(f) {
    case f.kind {
      TableCell(_) -> True
      _ -> False
    }
  })
}

fn render_table(rows: List(List(TableCellData)), bq_depth: Int) -> String {
  let non_empty =
    rows
    |> list.filter(fn(row) {
      list.any(row, fn(cell) { string.trim(cell.text) != "" })
    })
  let max_cols =
    list.fold(non_empty, 0, fn(acc, row) { int.max(acc, list.length(row)) })
  case non_empty, max_cols {
    [], _ | _, 0 -> ""
    // Single-cell layout table: unwrap as plain text instead of a 1x1 grid.
    [[TableCellData(text: text, ..)]], 1 -> blockquote_prefix(bq_depth) <> text
    [first, ..rest], cols -> {
      let pad = fn(row: List(TableCellData)) {
        let cells = list.map(row, fn(c) { escape_table_cell(c.text) })
        let missing = cols - list.length(cells)
        case missing > 0 {
          True -> list.append(cells, list.repeat("", missing))
          False -> cells
        }
      }
      let format_row = fn(cells: List(String)) {
        "| " <> string.join(cells, " | ") <> " |"
      }
      let header = format_row(pad(first))
      let sep = format_row(list.repeat("---", cols))
      let body = list.map(rest, fn(r) { format_row(pad(r)) })
      let prefix = blockquote_prefix(bq_depth)
      [header, sep, ..body]
      |> list.map(fn(line) { prefix <> line })
      |> string.join("\n")
    }
  }
}

fn escape_table_cell(text: String) -> String {
  text
  |> string.replace("|", "\\|")
  |> string.replace("\n", " ")
}

// ---------------------------------------------------------------------------
// Inline elements
// ---------------------------------------------------------------------------

fn start_link(state: State, attrs: List(Attribute)) -> State {
  // HTML forbids nested `<a>`; if malformed HTML nests one, ignore the inner.
  let in_link =
    list.any(state.frames, fn(f) {
      case f.kind {
        Link(_, _) -> True
        _ -> False
      }
    })
  case in_link {
    True -> state
    False -> {
      let href = resolve_link_href(find_attr(attrs, "href"), state.base_url)
      State(..state, frames: [
        empty_inline(Link(href: href, fallback_alt: None)),
        ..state.frames
      ])
    }
  }
}

fn end_link(state: State) -> State {
  case state.frames {
    [InlineFrame(kind: Link(href, fallback_alt), ..) as frame, ..rest] -> {
      let raw_label = collapse_inline_whitespace(frame_text(frame))
      let label = case raw_label, fallback_alt {
        "", Some(alt) -> alt
        l, _ -> l
      }
      let base = State(..state, frames: rest)
      case label {
        "" ->
          propagate_trailing_space(
            base,
            frame.leading_space || frame.trailing_space,
          )
        _ -> {
          let rendered = case href {
            None -> label
            Some(url) ->
              case label == url {
                True -> url
                False ->
                  "["
                  <> escape_link_label(label)
                  <> "]("
                  <> format_link_url(url)
                  <> ")"
              }
          }
          emit_inline_atom(
            base,
            rendered,
            frame.leading_space,
            frame.trailing_space,
          )
        }
      }
    }
    _ -> state
  }
}

fn push_inline_frame(state: State, kind: InlineKind) -> State {
  // Don't double-nest the same inline wrapper (e.g. `<b><b>x</b></b>`).
  let already = list.any(state.frames, fn(f) { f.kind == kind })
  case already {
    True -> state
    False -> State(..state, frames: [empty_inline(kind), ..state.frames])
  }
}

fn end_emphasis(state: State, expected: InlineKind, marker: String) -> State {
  case state.frames {
    [InlineFrame(kind: kind, ..) as frame, ..rest] if kind == expected -> {
      let inner = string.trim(frame_text(frame))
      let base = State(..state, frames: rest)
      case inner {
        "" ->
          propagate_trailing_space(
            base,
            frame.leading_space || frame.trailing_space,
          )
        _ ->
          emit_inline_atom(
            base,
            marker <> inner <> marker,
            frame.leading_space,
            frame.trailing_space,
          )
      }
    }
    _ -> state
  }
}

fn end_inline_code(state: State) -> State {
  case state.frames {
    [InlineFrame(kind: InlineCode, ..) as frame, ..rest] -> {
      let inner = string.trim(frame_text(frame))
      let base = State(..state, frames: rest)
      case inner {
        "" ->
          propagate_trailing_space(
            base,
            frame.leading_space || frame.trailing_space,
          )
        _ -> {
          let wrapped = wrap_inline_code(inner)
          emit_inline_atom(
            base,
            wrapped,
            frame.leading_space,
            frame.trailing_space,
          )
        }
      }
    }
    _ -> state
  }
}

fn handle_img(state: State, attrs: List(Attribute)) -> State {
  let src = find_attr(attrs, "src") |> option.unwrap("") |> string.trim
  let is_data = string.starts_with(string.lowercase(src), "data:")
  case is_data {
    True -> state
    False ->
      case find_attr(attrs, "alt") {
        None -> state
        Some(raw_alt) -> {
          let alt = collapse_inline_whitespace(raw_alt)
          case alt != "" && string.length(alt) <= max_img_alt_chars {
            False -> state
            True ->
              case record_link_fallback_alt(state.frames, alt) {
                Some(updated_frames) -> State(..state, frames: updated_frames)
                None -> emit_inline_atom(state, alt, False, False)
              }
          }
        }
      }
  }
}

/// If currently inside an `<a>` frame, stash the first meaningful `img[alt]`
/// as its fallback label (used only when the link carries no visible text).
fn record_link_fallback_alt(
  frames: List(InlineFrame),
  alt: String,
) -> Option(List(InlineFrame)) {
  case frames {
    [] -> None
    [InlineFrame(kind: Link(href, None), ..) as f, ..rest] ->
      Some([InlineFrame(..f, kind: Link(href, Some(alt))), ..rest])
    [InlineFrame(kind: Link(_, Some(_)), ..), ..] -> Some(frames)
    [head, ..rest] ->
      case record_link_fallback_alt(rest, alt) {
        Some(updated_rest) -> Some([head, ..updated_rest])
        None -> None
      }
  }
}

// ---------------------------------------------------------------------------
// Text emission & whitespace normalization
// ---------------------------------------------------------------------------

fn emit_normalized_text(state: State, raw: String) -> State {
  let #(lead, core, trail) = normalize_ws(raw)
  case core {
    "" ->
      case lead || trail {
        True -> mark_space(state)
        False -> state
      }
    _ -> emit_inline_atom(state, core, lead, trail)
  }
}

fn mark_space(state: State) -> State {
  case state.frames {
    [top, ..rest] -> {
      let updated = case top.has_content {
        True -> InlineFrame(..top, pending_space: True, trailing_space: True)
        False -> InlineFrame(..top, leading_space: True)
      }
      State(..state, frames: [updated, ..rest])
    }
    [] ->
      case state.doc.at_line_start {
        True -> state
        False -> State(..state, doc: DocBuf(..state.doc, pending_space: True))
      }
  }
}

fn mark_frame_space(state: State) -> State {
  case state.frames {
    [top, ..rest] -> {
      let updated = case top.has_content {
        True -> InlineFrame(..top, pending_space: True, trailing_space: True)
        False -> top
      }
      State(..state, frames: [updated, ..rest])
    }
    [] -> state
  }
}

fn propagate_trailing_space(state: State, had_space: Bool) -> State {
  case had_space {
    True -> mark_space(state)
    False -> state
  }
}

fn emit_inline_atom(
  state: State,
  text: String,
  lead_space: Bool,
  trail_space: Bool,
) -> State {
  case state.frames {
    [top, ..rest] -> {
      let need_space = top.has_content && { top.pending_space || lead_space }
      let chunks = case need_space {
        True -> [text, " ", ..top.chunks]
        False -> [text, ..top.chunks]
      }
      let leading = case top.has_content {
        True -> top.leading_space
        False -> top.leading_space || lead_space
      }
      let updated =
        InlineFrame(
          ..top,
          chunks: chunks,
          pending_space: trail_space,
          leading_space: leading,
          trailing_space: trail_space,
          has_content: True,
        )
      State(..state, frames: [updated, ..rest])
    }
    [] -> {
      let doc =
        emit_doc_text(
          state.doc,
          text,
          lead_space,
          trail_space,
          state.blockquote_depth,
        )
      State(..state, doc: doc)
    }
  }
}

fn emit_doc_text(
  doc: DocBuf,
  text: String,
  lead_space: Bool,
  trail_space: Bool,
  bq_depth: Int,
) -> DocBuf {
  let doc = flush_pending_break(doc, bq_depth)
  let need_space = !doc.at_line_start && { doc.pending_space || lead_space }
  let prefix = case doc.at_line_start && bq_depth > 0 {
    True -> blockquote_prefix(bq_depth)
    False -> ""
  }
  let chunks = case need_space {
    True -> [text, " ", ..doc.chunks]
    False ->
      case prefix == "" {
        True -> [text, ..doc.chunks]
        False -> [text, prefix, ..doc.chunks]
      }
  }
  DocBuf(
    chunks: chunks,
    pending_break: BreakNone,
    pending_space: trail_space,
    at_line_start: False,
    just_started_li: False,
    has_content: True,
  )
}

fn emit_list_marker(doc: DocBuf, marker: String, bq_depth: Int) -> DocBuf {
  let doc = flush_pending_break(doc, bq_depth)
  let prefix = blockquote_prefix(bq_depth)
  let chunks = case prefix == "" {
    True -> [marker, ..doc.chunks]
    False -> [marker, prefix, ..doc.chunks]
  }
  DocBuf(
    chunks: chunks,
    pending_break: BreakNone,
    pending_space: False,
    at_line_start: False,
    just_started_li: True,
    has_content: True,
  )
}

fn emit_raw_block(doc: DocBuf, block: String, bq_depth: Int) -> DocBuf {
  let doc = flush_pending_break(doc, bq_depth)
  DocBuf(
    chunks: [block, ..doc.chunks],
    pending_break: BreakNone,
    pending_space: False,
    at_line_start: False,
    just_started_li: False,
    has_content: True,
  )
}

fn upgrade_doc_break(doc: DocBuf, kind: Break) -> DocBuf {
  let next = case doc.pending_break, kind {
    BreakParagraph, _ | _, BreakParagraph -> BreakParagraph
    BreakLine, _ | _, BreakLine -> BreakLine
    BreakNone, BreakNone -> BreakNone
  }
  DocBuf(..doc, pending_break: next, pending_space: False)
}

fn flush_pending_break(doc: DocBuf, bq_depth: Int) -> DocBuf {
  case doc.has_content, doc.pending_break {
    False, _ -> DocBuf(..doc, pending_break: BreakNone)
    True, BreakNone -> doc
    True, BreakLine ->
      DocBuf(
        ..doc,
        chunks: ["\n", ..doc.chunks],
        pending_break: BreakNone,
        pending_space: False,
        at_line_start: True,
      )
    True, BreakParagraph -> {
      let sep = case bq_depth > 0 {
        True -> "\n" <> string.trim_end(blockquote_prefix(bq_depth)) <> "\n"
        False -> "\n\n"
      }
      DocBuf(
        ..doc,
        chunks: [sep, ..doc.chunks],
        pending_break: BreakNone,
        pending_space: False,
        at_line_start: True,
      )
    }
  }
}

fn frame_text(frame: InlineFrame) -> String {
  frame.chunks
  |> list.reverse
  |> string.concat
}

fn finalize_doc(doc: DocBuf) -> String {
  doc.chunks
  |> list.reverse
  |> string.concat
  |> string.split("\n")
  |> list.map(string.trim_end)
  |> collapse_blank_lines([], 0)
  |> string.join("\n")
  |> string.trim
}

fn collapse_blank_lines(
  lines: List(String),
  acc: List(String),
  blanks: Int,
) -> List(String) {
  case lines {
    [] -> list.reverse(acc)
    ["", ..rest] ->
      case blanks >= 1 {
        True -> collapse_blank_lines(rest, acc, blanks + 1)
        False -> collapse_blank_lines(rest, ["", ..acc], blanks + 1)
      }
    [line, ..rest] -> collapse_blank_lines(rest, [line, ..acc], 0)
  }
}

fn finalize_title(chunks: List(String)) -> Option(String) {
  let text =
    chunks
    |> list.reverse
    |> string.concat
    |> collapse_inline_whitespace
  case text {
    "" -> None
    t -> Some(t)
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn is_always_dropped(tag: String) -> Bool {
  case tag {
    "script"
    | "style"
    | "noscript"
    | "template"
    | "svg"
    | "iframe"
    | "canvas"
    | "object"
    | "embed"
    | "audio"
    | "video"
    | "button"
    | "select"
    | "option"
    | "textarea"
    | "input" -> True
    _ -> False
  }
}

fn is_chrome_tag(tag: String) -> Bool {
  case tag {
    "nav" | "footer" | "aside" -> True
    _ -> False
  }
}

fn blockquote_prefix(depth: Int) -> String {
  case depth <= 0 {
    True -> ""
    False -> string.repeat("> ", depth)
  }
}

fn find_attr(attrs: List(Attribute), name: String) -> Option(String) {
  case list.find(attrs, fn(attr) { string.lowercase(attr.name) == name }) {
    Ok(attr) -> Some(attr.value)
    Error(Nil) -> None
  }
}

fn parse_ol_start(attrs: List(Attribute)) -> Int {
  case find_attr(attrs, "start") {
    Some(raw) ->
      case int.parse(string.trim(raw)) {
        Ok(n) if n >= 0 -> n
        _ -> 1
      }
    None -> 1
  }
}

fn extract_code_lang(attrs: List(Attribute)) -> Option(String) {
  case find_attr(attrs, "class") {
    None -> None
    Some(cls) ->
      cls
      |> string.split(" ")
      |> list.find_map(fn(token) {
        let token = string.trim(token)
        let lower = string.lowercase(token)
        case string.starts_with(lower, "language-") {
          True -> clean_lang(string.drop_start(token, 9))
          False ->
            case string.starts_with(lower, "lang-") {
              True -> clean_lang(string.drop_start(token, 5))
              False -> Error(Nil)
            }
        }
      })
      |> option.from_result
  }
}

fn clean_lang(raw: String) -> Result(String, Nil) {
  let cleaned =
    raw
    |> string.to_graphemes
    |> list.filter(is_lang_char)
    |> string.concat
  case cleaned {
    "" -> Error(Nil)
    lang -> Ok(lang)
  }
}

fn is_lang_char(ch: String) -> Bool {
  case ch {
    "a"
    | "b"
    | "c"
    | "d"
    | "e"
    | "f"
    | "g"
    | "h"
    | "i"
    | "j"
    | "k"
    | "l"
    | "m"
    | "n"
    | "o"
    | "p"
    | "q"
    | "r"
    | "s"
    | "t"
    | "u"
    | "v"
    | "w"
    | "x"
    | "y"
    | "z"
    | "A"
    | "B"
    | "C"
    | "D"
    | "E"
    | "F"
    | "G"
    | "H"
    | "I"
    | "J"
    | "K"
    | "L"
    | "M"
    | "N"
    | "O"
    | "P"
    | "Q"
    | "R"
    | "S"
    | "T"
    | "U"
    | "V"
    | "W"
    | "X"
    | "Y"
    | "Z"
    | "0"
    | "1"
    | "2"
    | "3"
    | "4"
    | "5"
    | "6"
    | "7"
    | "8"
    | "9"
    | "-"
    | "_"
    | "+"
    | "#"
    | "." -> True
    _ -> False
  }
}

fn resolve_link_href(raw: Option(String), base_url: String) -> Option(String) {
  case raw {
    None -> None
    Some(href) -> {
      let trimmed = string.trim(href)
      let lower = string.lowercase(trimmed)
      case
        trimmed == ""
        || string.starts_with(lower, "javascript:")
        || string.starts_with(lower, "data:")
        || string.starts_with(lower, "vbscript:")
      {
        True -> None
        False ->
          case base_url == "" {
            True -> Some(trimmed)
            False ->
              case net.resolve_url(base_url, trimmed) {
                Ok(resolved) -> Some(resolved)
                Error(Nil) -> Some(trimmed)
              }
          }
      }
    }
  }
}

fn escape_link_label(label: String) -> String {
  label
  |> string.replace("[", "\\[")
  |> string.replace("]", "\\]")
}

fn format_link_url(url: String) -> String {
  case string.contains(url, " ") || string.contains(url, ")") {
    True -> "<" <> url <> ">"
    False -> url
  }
}

fn wrap_inline_code(code: String) -> String {
  let ticks = string.repeat("`", max_backtick_run(code) + 1)
  let needs_pad =
    string.starts_with(code, "`")
    || string.ends_with(code, "`")
    || string.starts_with(code, " ")
    || string.ends_with(code, " ")
  case needs_pad {
    True -> ticks <> " " <> code <> " " <> ticks
    False -> ticks <> code <> ticks
  }
}

fn choose_fence(body: String) -> String {
  let run = max_backtick_run(body)
  string.repeat("`", int.max(3, run + 1))
}

fn max_backtick_run(text: String) -> Int {
  text
  |> string.to_graphemes
  |> list.fold(#(0, 0), fn(acc, ch) {
    let #(best, cur) = acc
    case ch == "`" {
      True -> {
        let next = cur + 1
        #(int.max(best, next), next)
      }
      False -> #(best, 0)
    }
  })
  |> fn(pair) { pair.0 }
}

fn strip_one_leading_newline(s: String) -> String {
  case string.starts_with(s, "\n") {
    True -> string.drop_start(s, 1)
    False -> s
  }
}

fn strip_trailing_newlines(s: String) -> String {
  case string.ends_with(s, "\n") {
    True -> strip_trailing_newlines(string.drop_end(s, 1))
    False -> s
  }
}

/// Collapse runs of ASCII whitespace in `raw`, reporting whether `raw` had
/// leading whitespace, the collapsed interior text (trimmed), and whether it
/// had trailing whitespace.
fn normalize_ws(raw: String) -> #(Bool, String, Bool) {
  let graphemes = string.to_graphemes(raw)
  normalize_ws_loop(graphemes, False, False, False, [])
}

fn normalize_ws_loop(
  chars: List(String),
  saw_any_content: Bool,
  lead: Bool,
  pending_ws: Bool,
  acc: List(String),
) -> #(Bool, String, Bool) {
  case chars {
    [] -> #(
      lead,
      acc |> list.reverse |> string.concat,
      saw_any_content && pending_ws,
    )
    [ch, ..rest] ->
      case is_ascii_ws(ch) {
        True ->
          case saw_any_content {
            True -> normalize_ws_loop(rest, True, lead, True, acc)
            False -> normalize_ws_loop(rest, False, True, False, acc)
          }
        False -> {
          let next_acc = case saw_any_content && pending_ws {
            True -> [ch, " ", ..acc]
            False -> [ch, ..acc]
          }
          normalize_ws_loop(rest, True, lead, False, next_acc)
        }
      }
  }
}

fn collapse_inline_whitespace(text: String) -> String {
  let #(_, core, _) = normalize_ws(text)
  core
}

fn is_ascii_ws(ch: String) -> Bool {
  case ch {
    " " | "\t" | "\n" | "\r" | "\u{000C}" -> True
    _ -> False
  }
}
