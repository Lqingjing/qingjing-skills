#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Markdown Notes to Offline Single-File E-Book Compiler.

Converts standard multi-level Markdown notes into an interactive, zero-dependency,
single-file HTML offline e-book with sidebar navigation, full-text search,
and localStorage reading state persistence.

Usage:
    python build_ebook.py --source <notes.md> --output <book.html> --title "My Study Book" --build
    python build_ebook.py --source <notes.md> --check
"""
from __future__ import annotations

import argparse
import datetime as _dt
import html
import os
import re
import sys
from pathlib import Path


def esc(value: str) -> str:
    """Escape HTML entities safely."""
    return html.escape(str(value), quote=True)


def slugify(value: str) -> str:
    """Generate safe URL slug from UTF-8 strings."""
    value = re.sub(r"[^\w\u4e00-\u9fff]+", "-", value.lower()).strip("-")
    return value or "item"


def inline_markdown(text: str) -> str:
    """Render markdown inline tags (code, images, links, bold, italic)."""
    # 1. Inline code (protect with escaping)
    def _code_repl(m: re.Match) -> str:
        return f"<code>{esc(m.group(1))}</code>"

    text = re.sub(r"`([^`]+)`", _code_repl, text)

    # 2. Markdown images ![alt](url) before links
    text = re.sub(r"!\[([^\]]*)\]\(([^)]+)\)", r'<img src="\2" alt="\1" class="note-img" />', text)

    # 3. Bold italic, bold, italic
    text = re.sub(r"\*\*\*([^*]+)\*\*\*", r"<strong><em>\1</em></strong>", text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"\*([^*]+)\*", r"<em>\1</em>", text)

    # 4. Markdown links [text](url)
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', text)
    return text


def render_blocks(lines: list[str]) -> str:
    """Render a block of Markdown lines into structured HTML."""
    out = []
    in_code = False
    code_lang = ""
    code_buf = []
    in_list = False
    list_type = "ul"
    in_table = False
    table_buf = []

    def flush_list():
        nonlocal in_list
        if in_list:
            out.append(f"</{list_type}>")
            in_list = False

    def flush_table():
        nonlocal in_table, table_buf
        if in_table and table_buf:
            out.append("<table>")
            for idx, row in enumerate(table_buf):
                cells = [c.strip() for c in row.strip("|").split("|")]
                tag = "th" if idx == 0 else "td"
                out.append("<tr>" + "".join(f"<{tag}>{inline_markdown(c)}</{tag}>" for c in cells) + "</tr>")
            out.append("</table>")
            table_buf = []
            in_table = False

    i = 0
    while i < len(lines):
        line = lines[i]

        # Code fence check
        m_code = re.match(r"^```(\w*)", line)
        if m_code:
            if in_code:
                out.append(f'<pre><code class="{esc(code_lang)}">{esc("".join(code_buf))}</code></pre>')
                code_buf = []
                in_code = False
            else:
                flush_list()
                flush_table()
                in_code = True
                code_lang = m_code.group(1) or "text"
            i += 1
            continue

        if in_code:
            code_buf.append(line + "\n")
            i += 1
            continue

        stripped = line.strip()

        # Blank line
        if not stripped:
            flush_list()
            flush_table()
            i += 1
            continue

        # Horizontal rule
        if re.match(r"^(-{3,}|\*{3,}|_{3,})$", stripped):
            flush_list()
            flush_table()
            out.append("<hr>")
            i += 1
            continue

        # Table row
        if "|" in stripped and (stripped.startswith("|") or stripped.endswith("|")):
            if re.match(r"^\|?\s*[-:]+[-| :]*\|?$", stripped):
                # separator line
                i += 1
                continue
            flush_list()
            in_table = True
            table_buf.append(stripped)
            i += 1
            continue
        elif in_table:
            flush_table()

        # Headings (Level 4, 5, 6)
        m_h = re.match(r"^(#{4,6})\s+(.+)$", stripped)
        if m_h:
            flush_list()
            lvl = len(m_h.group(1))
            h_text = m_h.group(2)
            out.append(f"<h{lvl}>{inline_markdown(h_text)}</h{lvl}>")
            i += 1
            continue

        # Blockquote
        if stripped.startswith(">"):
            flush_list()
            quote_text = re.sub(r"^>\s?", "", stripped)
            out.append(f"<blockquote><p>{inline_markdown(quote_text)}</p></blockquote>")
            i += 1
            continue

        # Unordered list
        m_ul = re.match(r"^[-*+]\s+(.+)$", stripped)
        if m_ul:
            if not in_list or list_type != "ul":
                flush_list()
                in_list = True
                list_type = "ul"
                out.append("<ul>")
            out.append(f"<li>{inline_markdown(m_ul.group(1))}</li>")
            i += 1
            continue

        # Ordered list
        m_ol = re.match(r"^\d+\.\s+(.+)$", stripped)
        if m_ol:
            if not in_list or list_type != "ol":
                flush_list()
                in_list = True
                list_type = "ol"
                out.append("<ol>")
            out.append(f"<li>{inline_markdown(m_ol.group(1))}</li>")
            i += 1
            continue

        # Normal paragraph
        flush_list()
        out.append(f"<p>{inline_markdown(stripped)}</p>")
        i += 1

    flush_list()
    flush_table()
    if in_code and code_buf:
        out.append(f'<pre><code class="{esc(code_lang)}">{esc("".join(code_buf))}</code></pre>')

    return "\n".join(out)


def parse_markdown(text: str, exclude_pattern: str | None = None) -> tuple[list[dict], dict]:
    """
    Parse markdown into hierarchical structure: Chapters -> Sections/Pages -> Sub-entries.
    Strictly tracks code fences to avoid interpreting code comments as headings.
    """
    lines = text.splitlines()
    chapters: list[dict] = []
    current_chapter: dict | None = None
    current_section: dict | None = None
    stats = {"chapters": 0, "sections": 0, "entries": 0}

    fence_length = 0
    skipping_section = False

    for line_number, line in enumerate(lines, 1):
        stripped = line.strip()

        fence = re.match(r"^(`{3,})(.*)$", stripped)
        if fence_length or fence:
            if not fence_length:
                fence_length = len(fence.group(1))
            elif fence and len(fence.group(1)) >= fence_length and not fence.group(2):
                fence_length = 0
            if current_section:
                current_section["lines"].append(line)
            continue

        # Level 1 Heading: Chapter (# ...)
        m1 = re.match(r"^#\s+(.+)$", stripped)
        if m1:
            skipping_section = False
            title = m1.group(1).strip()
            current_chapter = {
                "id": f"chap-{slugify(title)}",
                "title": title,
                "sections": []
            }
            chapters.append(current_chapter)
            current_section = None
            stats["chapters"] += 1
            continue

        # Level 2 Heading: Section / Page (## ...)
        m2 = re.match(r"^##\s+(.+)$", stripped)
        if m2:
            title = m2.group(1).strip()
            if exclude_pattern and exclude_pattern.strip() and re.search(exclude_pattern, title, re.IGNORECASE):
                current_section = None
                skipping_section = True
                continue
            skipping_section = False

            if not current_chapter:
                current_chapter = {"id": "chap-default", "title": "Main Content", "sections": []}
                chapters.append(current_chapter)
                stats["chapters"] += 1

            current_section = {
                "id": f"sec-{slugify(title)}",
                "title": title,
                "chapter_title": current_chapter["title"],
                "line_number": line_number,
                "body_start": line_number + 1,
                "lines": [],
                "entries": []
            }
            current_chapter["sections"].append(current_section)
            stats["sections"] += 1
            continue

        if skipping_section:
            continue

        # Lines before the first section within a chapter (chapter intro)
        if current_chapter and not current_section:
            if stripped:
                intro_title = f"{current_chapter['title']} 导读"
                current_section = {
                    "id": f"sec-{slugify(current_chapter['title'])}-intro",
                    "title": intro_title,
                    "line_number": line_number,
                    "body_start": line_number,
                    "chapter_title": current_chapter["title"],
                    "lines": [line],
                    "entries": []
                }
                current_chapter["sections"].append(current_section)
                stats["sections"] += 1
            continue

        # Inside a section
        if current_section:
            current_section["lines"].append(line)

    # Parse sub-entries (Level 3 headings: ### ...) inside each section
    for ch in chapters:
        for sec in ch["sections"]:
            sec_lines = sec["lines"]
            entries = []
            curr_entry = {"title": "Overview", "lines": []}
            sec_in_code = False

            for entry_line, sline in enumerate(sec_lines, sec["body_start"]):
                s_strip = sline.strip()
                if s_strip.startswith("```"):
                    sec_in_code = not sec_in_code
                    curr_entry["lines"].append(sline)
                    continue

                if not sec_in_code:
                    m3 = re.match(r"^###\s+(.+)$", s_strip)
                    if m3:
                        if curr_entry["lines"] or curr_entry["title"] != "Overview":
                            entries.append(curr_entry)
                        curr_entry = {"title": m3.group(1).strip(), "line_number": entry_line, "lines": []}
                        stats["entries"] += 1
                        continue

                curr_entry["lines"].append(sline)

            if curr_entry["lines"] or curr_entry["title"] != "Overview":
                entries.append(curr_entry)
            sec["entries"] = entries

    return chapters, stats


def validate_anchors(chapters: list[dict]) -> None:
    locations = {}

    def register(anchor: str, location: str) -> None:
        if anchor in locations:
            raise ValueError(f"Duplicate anchor {anchor!r}: {locations[anchor]} conflicts with {location}")
        locations[anchor] = location

    for chapter in chapters:
        for section in chapter["sections"]:
            location = f'{chapter["title"]!r} / {section["title"]!r} (page starts at line {section["line_number"]})'
            register(f"page-{section['id']}", location)
            for entry in section["entries"]:
                if entry["title"] and entry["title"] != "Overview":
                    register(f"word-{slugify(entry['title'])}", f'{location} / {entry["title"]!r} (line {entry["line_number"]})')


def render_html(chapters: list[dict], stats: dict, title: str, templates_dir: Path) -> str:
    """Combine parsed structure with templates to generate standalone HTML."""
    shell_file = templates_dir / "shell.html"
    if not shell_file.exists():
        raise FileNotFoundError(f"Template not found: {shell_file}")

    shell = shell_file.read_text(encoding="utf-8")

    # Combine CSS
    css_parts = []
    for css_name in ["book_blue.css", "book_extensions.css", "reader.css"]:
        p = templates_dir / css_name
        if p.exists():
            css_parts.append(p.read_text(encoding="utf-8"))
    css_bundle = "\n".join(css_parts)

    # Read JS
    js_file = templates_dir / "reader.js"
    js_bundle = js_file.read_text(encoding="utf-8") if js_file.exists() else ""

    # Build TOC HTML
    toc_lines = ['<nav class="side-toc" id="side-toc">']
    for ch in chapters:
        toc_lines.append(f'<details class="toc-unit" data-unit="{esc(ch["title"])}" open>')
        toc_lines.append(f'<summary><span class="unit-badge">章</span><span class="unit-title">{esc(ch["title"])}</span></summary>')
        for sec in ch["sections"]:
            page_id = f"page-{sec['id']}"
            toc_lines.append(f'<details class="toc-p" data-p="{esc(sec["title"])}">')
            toc_lines.append(f'<summary><a class="toc-page" href="#{page_id}" data-page="{page_id}">{esc(sec["title"])}</a></summary>')
            for ent in sec["entries"]:
                if ent["title"] and ent["title"] != "Overview":
                    word_id = f"word-{slugify(ent['title'])}"
                    toc_lines.append(f'<a class="toc-word" href="#{word_id}" data-page="{page_id}" data-word="{word_id}">{esc(ent["title"])}</a>')
            toc_lines.append('</details>')
        toc_lines.append('</details>')
    toc_lines.append('</nav>')
    toc_html = "\n".join(toc_lines)

    # Build Pages HTML
    page_lines = []

    # Cover Page
    cover_html = f"""
    <section class="reader-page cover-page active" id="page-cover" data-page-id="cover">
      <header class="hero">
        <div class="hero-kicker">OFFLINE INTERACTIVE E-BOOK</div>
        <h1>{esc(title)}</h1>
        <div class="pill-row">
          <span class="pill">{stats['chapters']} 个章节</span>
          <span class="pill">{stats['sections']} 个阅读单元</span>
          <span class="pill">{stats['entries']} 个知识卡片</span>
          <span class="pill">零依赖单文件</span>
        </div>
        <p class="hero-base">从 Markdown 自动构建 · 本地浏览器双击即读 · {_dt.date.today().isoformat()}</p>
      </header>
      <div class="book-content">
        <div class="intro-note"><p>本电子书完全运行在本地浏览器，无须后台服务。书签、批注和阅读进度保存在本机 LocalStorage 中。</p></div>
        <div class="cover-actions"><button type="button" class="main-action" id="start-reading">开始阅读</button></div>
      </div>
    </section>
    """
    page_lines.append(cover_html)

    # Content Pages
    for ch in chapters:
        for sec in ch["sections"]:
            page_id = f"page-{sec['id']}"
            crumb = f"{sec['chapter_title']} · {sec['title']}"
            # Ensure data-unit and data-p are present for reader.js metadata inspection
            page_lines.append(f'<section class="reader-page" id="{page_id}" data-page-id="{page_id}" data-unit="{esc(sec["chapter_title"])}" data-p="{esc(sec["title"])}" data-crumb="{esc(crumb)}">')
            page_lines.append(f'<div class="page-meta">{esc(sec["chapter_title"])}</div>')
            page_lines.append(f'<h2 class="page-p-title chapter-heading">{esc(sec["title"])}</h2>')

            for ent in sec["entries"]:
                word_id = f"word-{slugify(ent['title'])}"
                if ent["title"] and ent["title"] != "Overview":
                    page_lines.append(f'<section class="entry word-section" id="{word_id}" data-word="{esc(ent["title"])}">')
                    # Ensure class="word-heading" is present for reader.js bookmark/search extraction
                    page_lines.append(f'<h3 class="word-heading">{esc(ent["title"])}</h3>')
                    page_lines.append(render_blocks(ent["lines"]))
                    page_lines.append('</section>')
                else:
                    if ent["lines"]:
                        page_lines.append('<div class="section-overview">')
                        page_lines.append(render_blocks(ent["lines"]))
                        page_lines.append('</div>')

            page_lines.append('</section>')

    pages_html = "\n".join(page_lines)

    # Assembly into Shell
    html_out = shell.replace("{{TITLE}}", esc(title))
    html_out = html_out.replace("{{CSS}}", css_bundle)
    html_out = html_out.replace("{{TOC}}", toc_html)
    html_out = html_out.replace("{{PAGES}}", pages_html)
    html_out = html_out.replace("{{SCRIPT}}", js_bundle)

    return html_out


def main():
    skill_root = Path(__file__).resolve().parent.parent
    default_source = skill_root / "demo" / "demo_notes.md"
    default_output = skill_root / "demo" / "demo_ebook.html"
    default_templates = skill_root / "templates"

    parser = argparse.ArgumentParser(description="Markdown to Offline Interactive E-Book Compiler")
    parser.add_argument("--source", type=str, default=str(default_source), help="Path to input markdown file")
    parser.add_argument("--output", type=str, default=str(default_output), help="Path to output HTML file")
    parser.add_argument("--title", type=str, default="知识笔记 · 离线电子教辅", help="Book title")
    parser.add_argument("--exclude-pattern", type=str, default="", help="Regex pattern to exclude sections (optional)")
    parser.add_argument("--templates", type=str, default=str(default_templates), help="Directory containing templates")
    parser.add_argument("--check", action="store_true", help="Dry run check without writing output")
    parser.add_argument("--build", action="store_true", help="Compile and write output HTML")

    args = parser.parse_args()

    src_path = Path(args.source).resolve()
    if not src_path.exists():
        print(f"[ERROR] Source file not found: {src_path}", file=sys.stderr)
        sys.exit(1)

    template_dir = Path(args.templates).resolve()
    if not template_dir.exists():
        print(f"[ERROR] Templates directory not found: {template_dir}", file=sys.stderr)
        sys.exit(1)

    raw_text = src_path.read_text(encoding="utf-8")
    chapters, stats = parse_markdown(raw_text, exclude_pattern=args.exclude_pattern)

    try:
        validate_anchors(chapters)
    except ValueError as error:
        sys.exit(f"[ERROR] {error}")

    print(f"[CHECK OK] Source parsed successfully:")
    print(f"  - Chapters: {stats['chapters']}")
    print(f"  - Sections/Pages: {stats['sections']}")
    print(f"  - Sub-entries: {stats['entries']}")

    if args.check and not args.build:
        print("[INFO] --check mode: no files written.")
        sys.exit(0)

    if args.build or not args.check:
        out_path = Path(args.output).resolve()
        out_path.parent.mkdir(parents=True, exist_ok=True)
        final_html = render_html(chapters, stats, args.title, template_dir)
        out_path.write_text(final_html, encoding="utf-8")
        file_size_kb = out_path.stat().st_size / 1024
        print(f"[BUILD OK] Single-file e-book generated successfully!")
        print(f"  - Output: {out_path} ({file_size_kb:.1f} KB)")


if __name__ == "__main__":
    main()
