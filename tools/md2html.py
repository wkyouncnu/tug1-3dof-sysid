#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
md2html.py — 의존성 없는 Markdown -> 인쇄용 HTML 변환기.

Pandoc 없이 THEORY.md / METHOD.md / RESULTS.md 를 PDF 로 만들기 위한 최소 변환기.
지원: ATX 헤딩, 펜스 코드블록, GFM 표, 인용문, 수평선, 목록(ul/ol),
      인라인 **굵게** / `코드` / [링크](url).

사용:
    python md2html.py input.md output.html "문서 제목"

그 다음 Chrome/Edge 헤드리스로:
    chrome --headless --disable-gpu --no-pdf-header-footer \
           --print-to-pdf=out.pdf file:///.../out.html
"""
import html
import re
import sys

CSS = """
@page { size: A4; margin: 18mm 15mm 18mm 15mm; }
body { font-family: "Malgun Gothic","맑은 고딕",system-ui,sans-serif;
       font-size: 9.6pt; line-height: 1.55; color: #16181d; margin: 0; }
h1 { font-size: 19pt; margin: 0 0 6pt; padding-bottom: 5pt;
     border-bottom: 2px solid #1f3a5f; color: #14305a; }
h2 { font-size: 13.5pt; margin: 18pt 0 6pt; padding: 3pt 0 3pt 7pt;
     border-left: 4px solid #1f3a5f; background: #eef2f7; color: #14305a;
     page-break-after: avoid; }
h3 { font-size: 11.2pt; margin: 12pt 0 4pt; color: #1f3a5f;
     page-break-after: avoid; }
h4 { font-size: 10pt; margin: 9pt 0 3pt; color: #33404f; }
p { margin: 4pt 0; }
ul, ol { margin: 4pt 0 4pt 0; padding-left: 17pt; }
li { margin: 1.5pt 0; }
code { font-family: Consolas,"D2Coding",monospace; font-size: 8.8pt;
       background: #f1f3f6; padding: 0.5pt 2.5pt; border-radius: 2px; }
pre { background: #f6f8fa; border: 1px solid #d8dee6; border-radius: 3px;
      padding: 6pt 8pt; overflow-x: auto; page-break-inside: avoid;
      margin: 6pt 0; }
pre code { background: none; padding: 0; font-size: 8.3pt; line-height: 1.38; }
table { border-collapse: collapse; width: 100%; margin: 6pt 0;
        font-size: 8.4pt; page-break-inside: avoid; }
th { background: #1f3a5f; color: #fff; font-weight: 600;
     padding: 3.5pt 5pt; text-align: left; border: 1px solid #1f3a5f; }
td { padding: 3pt 5pt; border: 1px solid #ccd3dc; vertical-align: top; }
tr:nth-child(even) td { background: #f7f9fb; }
blockquote { margin: 6pt 0; padding: 5pt 9pt; background: #fff8e6;
             border-left: 4px solid #d79a16; }
blockquote p { margin: 2pt 0; }
hr { border: 0; border-top: 1px solid #d3d9e0; margin: 12pt 0; }
a { color: #14305a; text-decoration: none; border-bottom: 1px dotted #8fa3bb; }
strong { color: #0f1b2d; }
.docfoot { margin-top: 16pt; padding-top: 6pt; border-top: 1px solid #d3d9e0;
           font-size: 8pt; color: #697585; }
"""

BR = '@@BR@@'

INLINE_CODE = re.compile(r'`([^`]+)`')
BOLD = re.compile(r'\*\*(.+?)\*\*')
LINK = re.compile(r'\[([^\]]+)\]\(([^)]+)\)')


def inline(text):
    """인라인 마크업 처리. 코드 스팬을 먼저 떼어내 이스케이프 충돌을 막는다."""
    spans = []

    def stash(m):
        spans.append(m.group(1))
        return '\x00%d\x00' % (len(spans) - 1)

    text = INLINE_CODE.sub(stash, text)
    text = html.escape(text, quote=False)
    text = BOLD.sub(r'<strong>\1</strong>', text)
    text = LINK.sub(lambda m: '<a href="%s">%s</a>'
                    % (html.escape(m.group(2), quote=True), m.group(1)), text)
    for i, s in enumerate(spans):
        text = text.replace('\x00%d\x00' % i,
                            '<code>%s</code>' % html.escape(s, quote=False))
    return text


def is_table_sep(line):
    s = line.strip()
    return (s.startswith('|') and set(s) <= set('|-: ') and '-' in s)


def convert(md):
    lines = md.split('\n')
    out = []
    i = 0
    n = len(lines)

    while i < n:
        ln = lines[i]
        s = ln.strip()

        # 펜스 코드블록
        if s.startswith('```'):
            i += 1
            buf = []
            while i < n and not lines[i].strip().startswith('```'):
                buf.append(lines[i])
                i += 1
            i += 1
            out.append('<pre><code>%s</code></pre>'
                       % html.escape('\n'.join(buf), quote=False))
            continue

        # 표
        if s.startswith('|') and i + 1 < n and is_table_sep(lines[i + 1]):
            def cells(row):
                r = row.strip()
                if r.startswith('|'):
                    r = r[1:]
                if r.endswith('|'):
                    r = r[:-1]
                return [c.strip() for c in r.split('|')]

            head = cells(s)
            i += 2
            body = []
            while i < n and lines[i].strip().startswith('|'):
                body.append(cells(lines[i]))
                i += 1
            t = ['<table><thead><tr>']
            t += ['<th>%s</th>' % inline(c) for c in head]
            t.append('</tr></thead><tbody>')
            for row in body:
                t.append('<tr>')
                t += ['<td>%s</td>' % inline(c) for c in row]
                t.append('</tr>')
            t.append('</tbody></table>')
            out.append(''.join(t))
            continue

        # 수평선
        if s in ('---', '***', '___'):
            out.append('<hr>')
            i += 1
            continue

        # 헤딩
        m = re.match(r'^(#{1,6})\s+(.*)$', s)
        if m:
            lvl = len(m.group(1))
            out.append('<h%d>%s</h%d>' % (lvl, inline(m.group(2)), lvl))
            i += 1
            continue

        # 인용문
        if s.startswith('>'):
            buf = []
            while i < n and lines[i].strip().startswith('>'):
                buf.append(lines[i].strip()[1:].strip())
                i += 1
            out.append('<blockquote>')
            for para in '\n'.join(buf).split('\n\n'):
                if para.strip():
                    out.append('<p>%s</p>' % inline(
                        para.strip().replace('\n', BR)).replace(BR, '<br>'))
            out.append('</blockquote>')
            continue

        # 목록
        if re.match(r'^[-*+]\s+', s) or re.match(r'^\d+[.)]\s+', s):
            ordered = bool(re.match(r'^\d+[.)]\s+', s))
            tag = 'ol' if ordered else 'ul'
            out.append('<%s>' % tag)
            while i < n:
                t = lines[i].strip()
                m2 = (re.match(r'^\d+[.)]\s+(.*)$', t) if ordered
                      else re.match(r'^[-*+]\s+(.*)$', t))
                if not m2:
                    break
                item = [m2.group(1)]
                i += 1
                # 들여쓴 연속행
                while (i < n and lines[i].startswith('  ')
                       and lines[i].strip()
                       and not re.match(r'^\s*[-*+]\s+', lines[i])
                       and not re.match(r'^\s*\d+[.)]\s+', lines[i])):
                    item.append(lines[i].strip())
                    i += 1
                out.append('<li>%s</li>' % inline(' '.join(item)))
            out.append('</%s>' % tag)
            continue

        # 빈 줄
        if not s:
            i += 1
            continue

        # 문단
        buf = []
        while i < n and lines[i].strip() and not re.match(
                r'^\s*(#{1,6}\s|```|\||>|[-*+]\s|\d+[.)]\s|---$|___$|\*\*\*$)',
                lines[i]):
            buf.append(lines[i].strip())
            i += 1
        if buf:
            out.append('<p>%s</p>'
                       % inline(BR.join(buf)).replace(BR, '<br>'))
        else:
            i += 1

    return '\n'.join(out)


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    src, dst = sys.argv[1], sys.argv[2]
    title = sys.argv[3] if len(sys.argv) > 3 else 'Document'
    with open(src, 'r', encoding='utf-8') as f:
        md = f.read()
    body = convert(md)
    doc = ('<!DOCTYPE html>\n<html lang="ko"><head><meta charset="utf-8">\n'
           '<title>%s</title>\n<style>%s</style></head>\n<body>\n%s\n'
           '<div class="docfoot">%s · Tug 1 3-DOF System Identification · '
           'AI Field Robotics Lab, Chungnam National University</div>\n'
           '</body></html>\n'
           % (html.escape(title), CSS, body, html.escape(title)))
    with open(dst, 'w', encoding='utf-8') as f:
        f.write(doc)
    print('wrote %s (%d bytes)' % (dst, len(doc.encode('utf-8'))))
    return 0


if __name__ == '__main__':
    sys.exit(main())
