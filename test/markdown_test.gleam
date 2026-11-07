//// Renderer tests for `nexus/ui/markdown` — the hostile-text contract
//// for the markdown path (see that module's doc). Every test renders
//// the element tree to the HTML a browser would actually parse via
//// `lustre/element.to_string` and asserts on it: model-fed payloads
//// (`<script>`, `javascript:` hrefs, inline HTML) must come out inert,
//// while normal chat markdown comes out semantic.

import gleam/string
import gleeunit/should
import lustre/element
import nexus/ui/markdown

fn rendered(md: String) -> String {
  markdown.render(md)
  |> element.fragment
  |> element.to_string
}

// ---- happy path: chat markdown comes out semantic -----------------------

pub fn blocks_render_semantically_test() {
  let out = rendered("## Plan\n\nRun **it** with `gleam run` now\n")
  should.be_true(string.contains(out, "<h2>Plan</h2>"))
  should.be_true(string.contains(out, "<strong>it</strong>"))
  should.be_true(string.contains(out, "<code>gleam run</code>"))
  should.be_true(string.contains(out, "<p>"))
}

pub fn fenced_code_renders_pre_code_test() {
  let out = rendered("```sh\ngleam test\n```\n")
  should.be_true(string.contains(out, "<pre><code>"))
  should.be_true(string.contains(out, "gleam test"))
}

pub fn tight_list_renders_bare_items_test() {
  let out = rendered("- one\n- two\n")
  should.be_true(string.contains(out, "<li>one</li>"))
  should.be_true(string.contains(out, "<li>two</li>"))
  // Tight: no paragraph wrappers inside items.
  should.be_false(string.contains(out, "<li><p>"))
}

pub fn gfm_table_renders_test() {
  let out = rendered("| a | b |\n|---|---|\n| 1 | 2 |\n")
  should.be_true(string.contains(out, "<table>"))
  should.be_true(string.contains(out, "<th"))
  // Cell text keeps mork's raw padding; the cell tags carry alignment.
  should.be_true(string.contains(out, "<td"))
  should.be_true(string.contains(out, "> 1 </td>"))
}

pub fn blockquote_and_hr_render_test() {
  let out = rendered("> quoted\n\n---\n")
  should.be_true(string.contains(out, "<blockquote>"))
  should.be_true(string.contains(out, "<hr"))
}

pub fn links_render_with_href_test() {
  let out = rendered("[docs](https://example.com/a)\n")
  should.be_true(string.contains(
    out,
    "<a href=\"https://example.com/a\">docs</a>",
  ))
}

pub fn anchor_and_relative_hrefs_allowed_test() {
  let out = rendered("[jump](#section-2) [file](docs/notes.md)\n")
  should.be_true(string.contains(out, "href=\"#section-2\""))
  should.be_true(string.contains(out, "href=\"docs/notes.md\""))
}

// ---- hostile path: model-fed markup comes out inert ---------------------

pub fn raw_html_block_is_inert_text_test() {
  let out = rendered("<script>alert(\"pwned\")</script>\n")
  // The payload surfaces as escaped text the user can read, never as a
  // tag the browser would parse.
  should.be_false(string.contains(out, "<script"))
  should.be_true(string.contains(out, "&lt;script&gt;"))
  should.be_true(string.contains(out, "alert"))
}

pub fn inline_html_is_inert_text_test() {
  let out = rendered("hello <b onclick=\"pwn()\">world</b> bye\n")
  should.be_false(string.contains(out, "<b>"))
  should.be_false(string.contains(out, "<b "))
  should.be_true(string.contains(out, "world"))
}

pub fn fenced_code_escapes_html_test() {
  let out = rendered("```\n<img src=x onerror=pwn()>\n```\n")
  should.be_false(string.contains(out, "<img"))
  should.be_true(string.contains(out, "&lt;img"))
}

pub fn javascript_href_is_refused_test() {
  let out = rendered("[click me](javascript:alert(1))\n")
  should.be_true(string.contains(out, "click me"))
  should.be_false(string.contains(out, "href=\"javascript"))
  should.be_false(string.contains(out, "<a"))
}

pub fn data_href_is_refused_test() {
  let out = rendered("[x](data:text/html;base64,PHNjcmlwdD4)\n")
  should.be_false(string.contains(out, "href=\"data:"))
}

pub fn scheme_check_is_case_insensitive_test() {
  let out = rendered("[x](JaVaScRiPt:alert(1))\n")
  should.be_false(string.contains(out, "href=\""))
}

pub fn images_render_as_links_not_img_test() {
  let out = rendered("![alt text](https://example.com/x.png)\n")
  should.be_false(string.contains(out, "<img"))
  should.be_true(string.contains(
    out,
    "<a href=\"https://example.com/x.png\">alt text</a>",
  ))
}

// ---- footnotes: references keep markers, definitions drop ---------------

pub fn footnote_reference_renders_marker_test() {
  let out = rendered("claim[^1]\n\n[^1]: the note\n")
  should.be_true(string.contains(out, "<sup>1</sup>"))
}
