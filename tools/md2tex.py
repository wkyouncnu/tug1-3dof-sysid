#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
md2tex.py — docs/PAPER.md  ->  docs/PAPER.tex  (XeLaTeX + xeCJK)

저장소의 tools/md2html.py 는 Markdown 을 HTML 로만 바꾸므로 "$...$" 수식을
조판하지 못한다. 이 스크립트는 PAPER.md 에 쓰인 Markdown 부분집합
(ATX 제목 / 파이프 표 / 펜스 코드 / $$ 디스플레이 수식 / 이미지+캡션 /
인용 / 번호·불릿 목록 / 인라인 **굵게**, `코드`, $수식$, [링크](url))을
LaTeX 로 변환한다. 수식은 원문 LaTeX 를 그대로 통과시킨다.

사용법:
    python tools/md2tex.py docs/PAPER.md docs/PAPER.tex
"""
import io
import os
import re
import sys

# ---------------------------------------------------------------- 문자 매핑

# 본문(텍스트 모드)에서 LaTeX 특수문자 이스케이프
ESC = {
    '\\': r'\textbackslash{}',
    '{': r'\{', '}': r'\}', '$': r'\$', '&': r'\&',
    '#': r'\#', '%': r'\%', '_': r'\_',
    '~': r'\textasciitilde{}', '^': r'\textasciicircum{}',
}

# 본문(텍스트 모드)의 비 ASCII 기호
TEXT_UNI = {
    '\u00a7': r'\S{}', '\u2014': '---', '\u2013': '--',
    '\u00b7': r'$\cdot$', '\u00b5': r'$\mu$', '\u00b0': r'$^\circ$',
    '\u00b1': r'$\pm$', '\u00bd': r'$\tfrac{1}{2}$', '\u00d7': r'$\times$',
    '\u00b2': r'$^2$', '\u00b9': r'$^1$', '\u2070': r'$^0$', '\u2082': r'$_2$',
    '\u1d40': r'$^{\top}$', '\u2212': r'$-$', '\u2026': r'$\dots$',
    '\u2190': r'$\leftarrow$', '\u2192': r'$\to$', '\u2194': r'$\leftrightarrow$',
    '\u21d2': r'$\Rightarrow$', '\u2208': r'$\in$', '\u2227': r'$\wedge$',
    '\u2248': r'$\approx$', '\u2260': r'$\neq$', '\u2264': r'$\leq$',
    '\u2265': r'$\geq$', '\u221e': r'$\infty$', '\u2298': r'$\oslash$',
    '\u2016': r'$\|$', '\u2308': r'$\lceil$', '\u2309': r'$\rceil$',
    '\u230a': r'$\lfloor$', '\u230b': r'$\rfloor$',
    '\u2605': r'$\bigstar$', '\u25a1': r'$\square$',
    '\u2705': r'$\checkmark$', '\u274c': r'$\times$',
    '\u26a0': r'$\triangle$', '\ufe0f': '',
    '\u03b8': r'$\theta$', '\u03c4': r'$\tau$', '\u03c7': r'$\chi$',
    '\u03b6': r'$\zeta$', '\u03c3': r'$\sigma$', '\u03c6': r'$\varphi$',
    '\u03c8': r'$\psi$', '\u03c1': r'$\rho$', '\u03c9': r'$\omega$',
    '\u03a3': r'$\Sigma$', '\u015c': r'$\hat{S}$', '\u0302': '',
    '\u2460': '(1)', '\u2461': '(2)', '\u2462': '(3)', '\u2463': '(4)',
    '\u2464': '(5)', '\u2465': '(6)', '\u2466': '(7)', '\u2467': '(8)',
    '\u2468': '(9)', '\u2469': '(10)',
    '\u251c': '|-', '\u2514': r'\textbackslash{}-',
}

# 수식 모드의 비 ASCII 기호
MATH_UNI = {
    '\u2014': '---', '\u2013': '--', '\u00b7': r'\cdot ',
    '\u00b5': r'\mu ', '\u00b0': r'^\circ ', '\u00b1': r'\pm ',
    '\u00bd': r'\tfrac{1}{2}', '\u00d7': r'\times ',
    '\u00b2': '^2', '\u00b9': '^1', '\u2070': '^0', '\u2082': '_2',
    '\u1d40': r'^{\top}', '\u2212': '-', '\u2026': r'\dots ',
    '\u2190': r'\leftarrow ', '\u2192': r'\to ', '\u2194': r'\leftrightarrow ',
    '\u21d2': r'\Rightarrow ', '\u2208': r'\in ', '\u2227': r'\wedge ',
    '\u2248': r'\approx ', '\u2260': r'\neq ', '\u2264': r'\leq ',
    '\u2265': r'\geq ', '\u221e': r'\infty ', '\u2298': r'\oslash ',
    '\u2016': r'\|', '\u2308': r'\lceil ', '\u2309': r'\rceil ',
    '\u230a': r'\lfloor ', '\u230b': r'\rfloor ',
    '\u2605': r'\bigstar ', '\u25a1': r'\square ',
    '\u03b8': r'\theta ', '\u03c4': r'\tau ', '\u03c7': r'\chi ',
    '\u03b6': r'\zeta ', '\u03c3': r'\sigma ', '\u03c6': r'\varphi ',
    '\u03c8': r'\psi ', '\u03c1': r'\rho ', '\u03c9': r'\omega ',
    '\u03a3': r'\Sigma ', '\u015c': r'\hat{S}', '\u0302': '',
    '\u00a7': r'\S ', '\ufe0f': '',
}

# 축자(verbatim) 블록: 한글은 그대로 두고 기호만 ASCII 화한다.
VERB_UNI = {
    '\u2190': '<-', '\u2192': '->', '\u2194': '<->', '\u21d2': '=>',
    '\u1d40': '^T', '\u00b2': '^2', '\u00b9': '^1', '\u2070': '^0',
    '\u2082': '_2', '\u2212': '-', '\u00b7': '.', '\u00d7': 'x',
    '\u2265': '>=', '\u2264': '<=', '\u2260': '!=', '\u2248': '~',
    '\u2208': ' in ', '\u2227': ' and ', '\u221e': 'inf',
    '\u2016': '||', '\u2298': ' ./ ', '\u2026': '...',
    '\u2308': 'ceil(', '\u2309': ')', '\u230a': 'floor(', '\u230b': ')',
    '\u2605': '*', '\u25a1': '[ ]', '\u00b5': 'u', '\u00b0': 'deg',
    '\u00b1': '+-', '\u00bd': '1/2', '\u2014': '--', '\u2013': '-',
    '\u00a7': 'sec.', '\u2705': '[v]', '\u274c': '[x]', '\u26a0': '[!]',
    '\ufe0f': '',
    '\u03b8': 'theta', '\u03c4': 'tau', '\u03c7': 'chi', '\u03b6': 'zeta',
    '\u03c3': 'sigma', '\u03c6': 'phi', '\u03c8': 'psi', '\u03c1': 'rho',
    '\u03a3': 'sum', '\u03c9': 'omega', '\u015c': 'S^', '\u0302': '^',
    '\u2460': '(1)', '\u2461': '(2)', '\u2462': '(3)', '\u2463': '(4)',
    '\u2464': '(5)', '\u2465': '(6)', '\u2466': '(7)', '\u2467': '(8)',
    '\u2468': '(9)', '\u2469': '(10)',
    '\u251c': '|-', '\u2514': '`-', '\u2502': '|',
}

TEXT_TR = {}
TEXT_TR.update({ord(k): v for k, v in ESC.items()})
TEXT_TR.update({ord(k): v for k, v in TEXT_UNI.items()})
MATH_TR = {ord(k): v for k, v in MATH_UNI.items()}
VERB_TR = {ord(k): v for k, v in VERB_UNI.items()}

SENT_B, SENT_E = '\x01', '\x02'


def is_cjk(ch):
    o = ord(ch)
    return (0xAC00 <= o <= 0xD7A3) or (0x3130 <= o <= 0x318F) or \
           (0x4E00 <= o <= 0x9FFF) or (0x3000 <= o <= 0x303F)


# ---------------------------------------------------------------- 인라인

TEXT_SYM_TR = {ord(k): v for k, v in TEXT_UNI.items()}
TXT_CMD = re.compile(r'\\(text|textbf|textit|textsf|textrm|textup|mbox)\{')


def mathconv(body):
    """수식 본문을 변환한다. \\text{...} 안쪽은 텍스트 모드 매핑을 쓴다."""
    out, k = [], 0
    while k < len(body):
        m = TXT_CMD.search(body, k)
        if not m:
            out.append(body[k:].translate(MATH_TR))
            break
        out.append(body[k:m.start()].translate(MATH_TR))
        b, depth, p = m.end(), 1, m.end()
        while p < len(body) and depth:
            if body[p] == '{':
                depth += 1
            elif body[p] == '}':
                depth -= 1
            p += 1
        out.append(m.group(0) + body[b:p - 1].translate(TEXT_SYM_TR) + '}')
        k = p
    return ''.join(out)


def esc_text(s):
    return s.translate(TEXT_TR)


LINK_RE = re.compile(r'\[([^\]]*)\]\(([^)]+)\)')
TOKEN_RE = re.compile(r'(`[^`]*`|\$[^$\n]+\$|\[[^\]]*\]\([^)]+\))')


def _link(txt, url):
    txt = txt.replace('`', '')
    if url.startswith('http'):
        return r'\href{%s}{\texttt{%s}}' % (url, esc_text(txt))
    if url.startswith('../'):
        url = url[3:]
    return r'\texttt{%s}' % esc_text(txt if txt else url)


DISC = r'\discretionary{}{}{}'


def breakable(t, thresh=28):
    """긴 고정폭 조각에 줄바꿈 기회를 준다. 짧은 식별자는 건드리지 않는다."""
    if len(t) <= thresh:
        return t
    return re.sub(r'([,;/)])(?=[^\s])', lambda m: m.group(1) + DISC, t)


def inline(s):
    """한 줄(또는 합친 문단)의 인라인 마크업을 LaTeX 로."""
    s = re.sub(r'\*\*(.+?)\*\*', SENT_B + r'\1' + SENT_E, s, flags=re.S)
    out = []
    for i, tok in enumerate(TOKEN_RE.split(s)):
        if i % 2 == 0:
            out.append(esc_text(tok))
            continue
        if tok.startswith('`'):
            out.append(r'\texttt{%s}' % breakable(esc_text(tok[1:-1])))
        elif tok.startswith('$'):
            out.append('$' + mathconv(tok[1:-1]) + '$')
        else:
            m = LINK_RE.match(tok)
            out.append(_link(m.group(1), m.group(2)))
    return ''.join(out).replace(SENT_B, r'\textbf{').replace(SENT_E, '}')


def tocsafe(s):
    s = re.sub(r'\$[^$]*\$', '', s)
    s = s.replace('**', '').replace('`', '').replace('\u2605', '')
    s = re.sub(r'\s+', ' ', s).strip()
    return esc_text(s)


# ---------------------------------------------------------------- 폭 추정

def est(s):
    t = s.replace('**', '').replace('`', '')

    def mrepl(m):
        b = m.group(1)
        b = re.sub(r'\\(mathrm|mathtt|mathbf|boldsymbol|text|mathcal'
                   r'|operatorname|left|right|,|;|!|:)', '', b)
        b = re.sub(r'\\[a-zA-Z]+', 'x', b)
        b = re.sub(r'[{}\\ ]', '', b)
        return b

    t = re.sub(r'\$([^$]*)\$', mrepl, t)
    t = LINK_RE.sub(lambda m: m.group(1).replace('`', ''), t)
    return sum(2 if is_cjk(c) else 1 for c in t)


def vwidth(line):
    """고정폭 블록의 1줄 폭 (라틴 1 글자 = 1 단위)."""
    return sum(1.667 if is_cjk(c) else 1 for c in line)


# ---------------------------------------------------------------- 블록 변환

def strip_envs(t):
    pat = re.compile(r'\\begin\{([A-Za-z]+\*?)\}(\[[^\]]*\])?(\{[^}]*\})?'
                     r'(.*?)\\end\{\1\}', re.S)
    for _ in range(8):
        new = pat.sub('ENV', t)
        if new == t:
            break
        t = new
    return t


def split_text_groups(inner):
    """\\boxed{} 내부를 \\text{...} 단위로 쪼개 텍스트/수식 조각 목록으로."""
    out, k = [], 0
    while k < len(inner):
        j = inner.find(r'\text{', k)
        if j < 0:
            tail = inner[k:]
            if tail.strip():
                out.append(('m', tail))
            break
        pre = inner[k:j]
        if pre.strip():
            out.append(('m', pre))
        p, depth = j + 6, 1
        while p < len(inner) and depth:
            if inner[p] == '{':
                depth += 1
            elif inner[p] == '}':
                depth -= 1
            p += 1
        out.append(('t', inner[j + 6:p - 1]))
        k = p
    return out


def display_math(body):
    tagm = re.search(r'\\tag\{([^}]*)\}', body)
    tag = tagm.group(1) if tagm else None
    if tagm:
        body = body.replace(tagm.group(0), '')
    body = mathconv(body).strip()

    # 한글 서술을 담은 강조상자는 줄바꿈이 되는 텍스트 상자로 바꾼다.
    if tag is None and body.startswith(r'\boxed{') and r'\text{' in body:
        inner = body[len(r'\boxed{'):]
        inner = inner.rstrip()
        if inner.endswith('}'):
            inner = inner[:-1]
        inner = inner.replace(r'\;', ' ').strip()
        parts = []
        for kind, frag in split_text_groups(inner):
            if kind == 't':
                parts.append(frag.strip())
            else:
                f = re.sub(r'(\\|\s)+$', '', frag.strip())
                if f:
                    parts.append('$' + f + '$')
        return '\\keybox{%s}\n' % ' '.join(parts)

    core = strip_envs(body)
    if r'\\' in core:
        env = 'aligned' if '&' in core else 'gathered'
        body = '\\begin{%s}\n%s\n\\end{%s}' % (env, body, env)
    tagline = ('\\tag{%s}' % tag) if tag else ''
    return '\\begin{equation*}\n%s %s\n\\end{equation*}\n' % (body, tagline)


SEP_RE = re.compile(r'^\|[\s:|-]+\|$')


SPAN_RE = re.compile(r'`[^`]*`|\$[^$]*\$')


def cells(row):
    """표 한 행을 칸으로 나눈다. 수식/코드 스팬 안의 | 는 구분자가 아니다."""
    keep = []

    def mask(m):
        keep.append(m.group(0))
        return '\x1f%d\x1f' % (len(keep) - 1)

    masked = SPAN_RE.sub(mask, row.strip().strip('|'))
    out = []
    for c in masked.split('|'):
        out.append(re.sub(r'\x1f(\d+)\x1f',
                          lambda m: keep[int(m.group(1))], c).strip())
    return out


def table(rows):
    grid = [cells(r) for r in rows]
    hdr, data = grid[0], grid[2:]
    ncol = len(hdr)
    data = [(r + [''] * (ncol - len(r)))[:ncol] for r in data]
    w = [max([est(hdr[c])] + [est(r[c]) for r in data]) for c in range(ncol)]

    if ncol >= 7:
        size, unit, budget = r'\scriptsize', 0.123, 128.0
    else:
        size, unit, budget = r'\footnotesize', 0.141, 110.0
    budget -= 1.6 * ncol

    if sum(w) <= budget:
        spec = 'l' * ncol
    else:
        wide = [c for c in range(ncol) if w[c] > 24]
        if not wide:
            wide = [ncol - 1]
        narrow_u = sum(w[c] for c in range(ncol) if c not in wide)
        avail = budget - narrow_u
        tot = float(sum(w[c] for c in wide)) or 1.0
        spec = ''
        for c in range(ncol):
            if c in wide:
                cm = max(1.6, avail * (w[c] / tot) * unit)
                spec += 'p{%.2fcm}' % cm
            else:
                spec += 'l'

    long_tbl = len(data) >= 15
    env = 'longtable' if long_tbl else 'tabular'
    L = []
    if long_tbl:
        L.append('{%s\\setlength{\\tabcolsep}{3pt}' % size)
        L.append('\\begin{longtable}{@{}%s@{}}' % spec)
        L.append('\\toprule')
        L.append(' & '.join('\\textbf{%s}' % inline(h) for h in hdr) + ' \\\\')
        L.append('\\midrule')
        L.append('\\endfirsthead')
        L.append('\\toprule')
        L.append(' & '.join('\\textbf{%s}' % inline(h) for h in hdr) + ' \\\\')
        L.append('\\midrule')
        L.append('\\endhead')
        L.append('\\bottomrule')
        L.append('\\endlastfoot')
    else:
        L.append('\\begin{center}%s\\setlength{\\tabcolsep}{3pt}' % size)
        L.append('\\begin{tabular}{@{}%s@{}}' % spec)
        L.append('\\toprule')
        L.append(' & '.join('\\textbf{%s}' % inline(h) for h in hdr) + ' \\\\')
        L.append('\\midrule')
    for r in data:
        L.append(' & '.join(inline(c) for c in r) + ' \\\\')
    if long_tbl:
        L.append('\\end{longtable}}')
    else:
        L.append('\\bottomrule')
        L.append('\\end{tabular}')
        L.append('\\end{center}')
    return '\n'.join(L) + '\n'


def verbatim(lines):
    txt = [l.translate(VERB_TR).replace('\t', '    ') for l in lines]
    mw = max([vwidth(l) for l in txt] + [1])
    if mw <= 86:
        size = r'\small'
    elif mw <= 97:
        size = r'\footnotesize'
    else:
        size = r'\scriptsize'
    return ('\\begin{Verbatim}[fontsize=%s,frame=single,framesep=2.2mm,'
            'rulecolor=\\color{black!35}]\n%s\n\\end{Verbatim}\n'
            % (size, '\n'.join(txt)))


CAP_RE = re.compile(r'^\*\*\uadf8\ub9bc\s*\d+\.\*\*\s*')


def figure(path, caption):
    base = os.path.basename(path)
    cap = CAP_RE.sub('', caption).strip()
    return ('\\begin{figure}[htbp]\n\\centering\n'
            '\\includegraphics[width=\\linewidth,height=0.40\\textheight,'
            'keepaspectratio]{%s}\n\\caption{%s}\n\\end{figure}\n'
            % (base, inline(cap)))


# ---------------------------------------------------------------- 메인 파서

STRUCT = re.compile(r'^(#{1,6} |```|\$\$|\||!\[|>|\s*[-*] |\s*\d+\. |---\s*$)')


def convert(md):
    L = md.split('\n')
    n = len(L)
    out = []

    # 서두(제목 블록)는 생성기 쪽에서 직접 조판한다 — "## 초록" 부터 변환.
    i = 0
    while i < n and not L[i].startswith('## '):
        i += 1

    while i < n:
        line = L[i]
        s = line.strip()

        if s == '':
            i += 1
            continue

        if s == '---':
            i += 1
            continue

        # 제목
        m = re.match(r'^(#{2,4})\s+(.*)$', line)
        if m:
            lvl, txt = len(m.group(1)), m.group(2).strip()
            cmd = {2: 'section', 3: 'subsection', 4: 'subsubsection'}[lvl]
            out.append('\\phantomsection')
            out.append('\\%s*{%s}' % (cmd, inline(txt)))
            if lvl <= 3:
                out.append('\\addcontentsline{toc}{%s}{%s}'
                           % (cmd, tocsafe(txt)))
            out.append('')
            i += 1
            continue

        # 펜스 코드
        if s.startswith('```'):
            j = i + 1
            blk = []
            while j < n and not L[j].strip().startswith('```'):
                blk.append(L[j])
                j += 1
            out.append(verbatim(blk))
            i = j + 1
            continue

        # 디스플레이 수식
        if s == '$$':
            j = i + 1
            blk = []
            while j < n and L[j].strip() != '$$':
                blk.append(L[j])
                j += 1
            out.append(display_math('\n'.join(blk)))
            i = j + 1
            continue

        # 표
        if s.startswith('|') and i + 1 < n and SEP_RE.match(L[i + 1].strip()):
            j = i
            rows = []
            while j < n and L[j].strip().startswith('|'):
                rows.append(L[j])
                j += 1
            out.append(table(rows))
            i = j
            continue

        # 그림
        if s.startswith('!['):
            m = re.match(r'^!\[([^\]]*)\]\(([^)]+)\)', s)
            path = m.group(2)
            j = i + 1
            while j < n and L[j].strip() == '':
                j += 1
            cap = []
            if j < n and L[j].lstrip().startswith('**\uadf8\ub9bc'):
                while j < n and L[j].strip() != '':
                    cap.append(L[j].strip())
                    j += 1
            out.append(figure(path, ' '.join(cap) if cap else m.group(1)))
            i = j
            continue

        # 인용
        if s.startswith('>'):
            j = i
            blk = []
            while j < n and L[j].strip().startswith('>'):
                blk.append(re.sub(r'^\s*>\s?', '', L[j]))
                j += 1
            paras, cur = [], []
            for b in blk:
                if b.strip() == '':
                    if cur:
                        paras.append(' '.join(cur))
                    cur = []
                else:
                    cur.append(b.strip())
            if cur:
                paras.append(' '.join(cur))
            out.append('\\begin{quote}\\small\n' +
                       '\n\n'.join(inline(p) for p in paras) +
                       '\n\\end{quote}\n')
            i = j
            continue

        # 목록
        om = re.match(r'^(\d+)\.\s+(.*)$', line)
        bm = re.match(r'^[-*]\s+(.*)$', line)
        if om or bm:
            ordered = om is not None
            items, cur = [], None
            j = i
            while j < n:
                l = L[j]
                mm = (re.match(r'^\d+\.\s+(.*)$', l) if ordered
                      else re.match(r'^[-*]\s+(.*)$', l))
                if mm:
                    if cur is not None:
                        items.append(cur)
                    cur = [mm.group(1)]
                    j += 1
                    continue
                if l.strip() == '':
                    nxt = L[j + 1] if j + 1 < n else ''
                    cont = (re.match(r'^\d+\.\s' if ordered else r'^[-*]\s',
                                     nxt) or re.match(r'^\s\s+\S', nxt))
                    if cont:
                        cur.append('\x00')
                        j += 1
                        continue
                    break
                if re.match(r'^\s+\S', l) and cur is not None:
                    cur.append(l.strip())
                    j += 1
                    continue
                break
            if cur is not None:
                items.append(cur)
            envn = 'enumerate' if ordered else 'itemize'
            out.append('\\begin{%s}[leftmargin=1.5em,itemsep=2pt,'
                       'parsep=2pt,topsep=3pt]' % envn)
            for it in items:
                body = ' '.join(it).replace(' \x00 ', '\n\n').replace('\x00', '\n\n')
                chunks = [c.strip() for c in body.split('\n\n') if c.strip()]
                out.append('\\item ' + '\n\n'.join(inline(c) for c in chunks))
            out.append('\\end{%s}\n' % envn)
            i = j
            continue

        # 문단
        j = i
        buf = []
        while j < n:
            l = L[j]
            if l.strip() == '':
                break
            if j > i and STRUCT.match(l):
                break
            buf.append(l.strip())
            j += 1
        out.append(inline(' '.join(buf)))
        out.append('')
        i = j

    return '\n'.join(out)


# ---------------------------------------------------------------- 전문/후문

POSTAMBLE = "\n\\end{document}\n"


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else 'docs/PAPER.md'
    dst = sys.argv[2] if len(sys.argv) > 2 else 'docs/PAPER.tex'
    md = io.open(src, encoding='utf-8').read()
    head = io.open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                'paper_front.tex'), encoding='utf-8').read()
    body = convert(md)
    tex = head + body + POSTAMBLE
    io.open(dst, 'w', encoding='utf-8', newline='\n').write(tex)

    # 매핑되지 않은 비 ASCII 기호 점검
    bad = {}
    for ch in tex:
        o = ord(ch)
        if o < 128 or is_cjk(ch):
            continue
        bad[ch] = bad.get(ch, 0) + 1
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')
    print('wrote %s (%d lines)' % (dst, tex.count('\n') + 1))
    if bad:
        print('unmapped non-ASCII: ' +
              ', '.join('U+%04X x%d' % (ord(k), v) for k, v in
                        sorted(bad.items(), key=lambda kv: -kv[1])))
    else:
        print('unmapped non-ASCII: none')


if __name__ == '__main__':
    main()
