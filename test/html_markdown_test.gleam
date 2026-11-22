//// Unit tests for `nexus/html_markdown`: pure HTML-to-Markdown conversion.

import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import nexus/html_markdown

pub fn headings_and_paragraphs_test() {
  let html =
    "<html><head><title>  Hello   World  </title><meta charset=\"utf-8\"></head>"
    <> "<body><h1>Main Title</h1><p>First paragraph.</p>"
    <> "<h2>Sub Heading</h2><p>Second   paragraph\nwith\tspaces.</p></body></html>"
  let converted = html_markdown.convert(html, "https://example.com/")
  converted.title |> should.equal(Some("Hello World"))
  converted.markdown
  |> should.equal(
    "# Main Title\n\nFirst paragraph.\n\n## Sub Heading\n\nSecond paragraph with spaces.",
  )
}

pub fn nested_lists_and_ordered_lists_test() {
  let html =
    "<ul><li>Alpha<ul><li>Nested A</li><li>Nested B</li></ul></li><li>Beta</li></ul>"
    <> "<ol start=\"3\"><li>Third</li><li>Fourth</li></ol>"
  let converted = html_markdown.convert(html, "")
  converted.markdown
  |> should.equal(
    "- Alpha\n  - Nested A\n  - Nested B\n- Beta\n\n3. Third\n4. Fourth",
  )
}

pub fn list_item_with_inner_paragraph_stays_on_bullet_line_test() {
  let html = "<ul><li><p>First item</p></li><li><p>Second item</p></li></ul>"
  let converted = html_markdown.convert(html, "")
  converted.markdown |> should.equal("- First item\n- Second item")
}

pub fn pre_code_preserves_indentation_and_blank_lines_test() {
  let html =
    "<p>Before</p>"
    <> "<pre><code class=\"language-gleam\">\n"
    <> "pub fn main() {\n"
    <> "  let x = 1\n"
    <> "\n"
    <> "  x + 2\n"
    <> "}\n"
    <> "</code></pre>"
    <> "<p>After</p>"
  let converted = html_markdown.convert(html, "")
  converted.markdown
  |> should.equal(
    "Before\n\n```gleam\npub fn main() {\n  let x = 1\n\n  x + 2\n}\n```\n\nAfter",
  )
}

pub fn pre_containing_triple_backticks_uses_longer_fence_test() {
  let html = "<pre><code>```\nhi\n```</code></pre>"
  let converted = html_markdown.convert(html, "")
  converted.markdown |> should.equal("````\n```\nhi\n```\n````")
}

pub fn inline_boundary_spacing_and_formatting_test() {
  // Whitespace between adjacent inline tags must survive.
  let html =
    "<p><b>a</b> <i>b</i> and <code>c</code>, <strong>   </strong><em></em></p>"
  let converted = html_markdown.convert(html, "")
  converted.markdown |> should.equal("**a** *b* and `c`,")

  // Leading/trailing whitespace inside emphasis moves outside the markers.
  let html2 = "<p>hello<b> world </b>again</p>"
  let converted2 = html_markdown.convert(html2, "")
  converted2.markdown |> should.equal("hello **world** again")

  // Inline code containing a backtick uses double backticks.
  let html3 = "<p>Run <code>echo `hi`</code> now.</p>"
  let converted3 = html_markdown.convert(html3, "")
  converted3.markdown |> should.equal("Run `` echo `hi` `` now.")
}

pub fn links_absolute_relative_fragment_and_unsafe_schemes_test() {
  let base = "https://example.com/docs/v1/intro.html"
  let html =
    "<p>"
    <> "<a href=\"https://other.test/a\">Absolute</a>, "
    <> "<a href=\"guide.html\">Relative</a>, "
    <> "<a href=\"../v2/api.html\">Parent</a>, "
    <> "<a href=\"#install\">Fragment</a>, "
    <> "<a href=\"javascript:alert(1)\">Click</a>, "
    <> "<a href=\"data:text/html,evil\">Data</a>, "
    <> "<a href=\"https://same.test/\">https://same.test/</a>, "
    <> "<a href=\"/icon\"></a>, "
    <> "<a href=\"/home\"><img src=\"logo.png\" alt=\"Home\"></a>"
    <> "</p>"
  let converted = html_markdown.convert(html, base)
  converted.markdown
  |> should.equal(
    "[Absolute](https://other.test/a), "
    <> "[Relative](https://example.com/docs/v1/guide.html), "
    <> "[Parent](https://example.com/docs/v2/api.html), "
    <> "[Fragment](https://example.com/docs/v1/intro.html#install), "
    <> "Click, Data, https://same.test/, , [Home](https://example.com/home)",
  )
}

pub fn tables_and_irregular_rows_test() {
  let html =
    "<table><thead><tr><th>Name</th><th>Value</th></tr></thead>"
    <> "<tbody><tr><td>A|B</td><td>1</td></tr>"
    <> "<tr><td>Only one</td></tr></tbody></table>"
  let converted = html_markdown.convert(html, "")
  converted.markdown
  |> should.equal(
    "| Name | Value |\n| --- | --- |\n| A\\|B | 1 |\n| Only one |  |",
  )
}

pub fn blockquote_and_hr_and_br_test() {
  let html =
    "<blockquote><p>Line one<br>Line two</p><p>Second para</p></blockquote>"
    <> "<hr><p>Done</p>"
  let converted = html_markdown.convert(html, "")
  converted.markdown
  |> should.equal("> Line one\n> Line two\n>\n> Second para\n\n---\n\nDone")
}

pub fn scripts_styles_svg_comments_and_controls_stripped_test() {
  let html =
    "<!-- secret comment -->"
    <> "<style>body { color: red; }</style>"
    <> "<script>alert('<p>xss</p>')</script>"
    <> "<svg><g><text>Icon</text></g></svg>"
    <> "<button>Submit</button><select><option>Opt</option></select>"
    <> "<p>Visible text</p>"
  let converted = html_markdown.convert(html, "")
  converted.markdown |> should.equal("Visible text")
}

pub fn chrome_dropped_with_empty_body_fallback_test() {
  // Normal page: nav/footer/aside dropped.
  let normal =
    "<nav><a href=\"/\">Home</a></nav>"
    <> "<main><p>Article body here.</p></main>"
    <> "<aside>Sidebar ads</aside>"
    <> "<footer>Copyright 2026</footer>"
  let c1 = html_markdown.convert(normal, "https://example.com/")
  c1.markdown |> should.equal("Article body here.")

  // Nav-only page: dropping chrome leaves empty body -> falls back cleanly.
  let nav_only = "<nav><ul><li>Only content</li></ul></nav>"
  let c2 = html_markdown.convert(nav_only, "https://example.com/")
  c2.markdown |> should.equal("- Only content")
}

pub fn entities_malformed_html_and_unicode_test() {
  let html =
    "<p>5 &lt; 10 &amp; &quot;café&quot; — 日本語 🚀<p>Unclosed second"
    <> "<ul><li>One<li>Two</ul>"
  let converted = html_markdown.convert(html, "")
  converted.title |> should.equal(None)
  should.be_true(string.contains(
    converted.markdown,
    "5 < 10 & \"café\" — 日本語 🚀",
  ))
  should.be_true(string.contains(converted.markdown, "Unclosed second"))
  should.be_true(string.contains(converted.markdown, "- One\n- Two"))
}

pub fn void_tags_in_dropped_subtrees_and_unclosed_inline_or_cell_test() {
  // Void elements inside dropped subtrees (`<img>` in `<footer>`, bare
  // `<input>`) must not leave `drop_depth` stuck > 0.
  let with_footer_img = "<footer>© <img src=\"x\"></footer><p>After</p>"
  html_markdown.convert(with_footer_img, "https://example.com/").markdown
  |> should.equal("After")

  let with_input = "<input type=\"text\" value=\"q\"><p>After input</p>"
  html_markdown.convert(with_input, "https://example.com/").markdown
  |> should.equal("After input")

  // Unclosed `<td>` and `<a>` must never trap subsequent body content.
  let unclosed_td = "<table><tr><td>c1<td>c2</table><p>After table</p>"
  let td_md = html_markdown.convert(unclosed_td, "").markdown
  should.be_true(string.contains(td_md, "c1"))
  should.be_true(string.contains(td_md, "After table"))

  let unclosed_a = "<p><a href=\"/x\">unclosed link</p><p>After link</p>"
  let a_md = html_markdown.convert(unclosed_a, "https://example.com").markdown
  should.be_true(string.contains(a_md, "[unclosed link](https://example.com/x)"))
  should.be_true(string.contains(a_md, "After link"))
}
