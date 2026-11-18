#!/usr/bin/env python3
"""Writes the site's "thanks to the issue reporters" line from the repo's issues.

Run by the Pages workflow before it uploads site/ (daily, on push and by hand),
so the line stays current without committing anything. Every issue (open or
closed, pull requests excluded) by someone other than the repository owner or a
bot counts; each reporter is listed once, newest first, with links to their
issues. The Chinese text lives in site/index.html, English and Japanese in
site/i18n.js; with no reporters the paragraph is hidden.

  GH_TOKEN=... python3 scripts/issue_reporters.py [owner/repo]

Standard library only.
"""
import html
import json
import os
import re
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INDEX = os.path.join(ROOT, 'site', 'index.html')
I18N = os.path.join(ROOT, 'site', 'i18n.js')


def fetch_issues(repo, token):
    issues, page = [], 1
    while True:
        req = urllib.request.Request(
            f'https://api.github.com/repos/{repo}/issues?state=all&per_page=100&page={page}',
            headers={'Accept': 'application/vnd.github+json', 'User-Agent': 'karaoke-battle-site'},
        )
        if token:
            req.add_header('Authorization', f'Bearer {token}')
        with urllib.request.urlopen(req, timeout=30) as r:
            batch = json.load(r)
        issues += batch
        if len(batch) < 100:
            return issues
        page += 1


def reporters(issues, owner):
    """[(login, [(number, title, url), ...])], newest reporter first."""
    by_user = {}
    for i in sorted(issues, key=lambda i: -i['number']):
        if 'pull_request' in i:
            continue
        user = i.get('user') or {}
        login = user.get('login', '')
        if not login or login.lower() == owner.lower() or user.get('type') == 'Bot' or login.endswith('[bot]'):
            continue
        by_user.setdefault(login, []).append((i['number'], i['title'].strip(), i['html_url']))
    return list(by_user.items())


def render(people, lang):
    def issue_links(items, sep):
        return sep.join(f'<a href="{html.escape(u)}" target="_blank" rel="noopener">#{n} {html.escape(t)}</a>' for n, t, u in items)

    if lang == 'en':
        body = ', '.join(f'{html.escape(login)} ({issue_links(items, ", ")})' for login, items in people)
        return f'Thanks also to the users who reported issues on GitHub: {body}.'
    body = '、'.join(f'{html.escape(login)}（{issue_links(items, "、")}）' for login, items in people)
    if lang == 'ja':
        return f'GitHub で問題を報告してくれたユーザーの皆さんにも感謝します：{body}。'
    return f'也感謝在 GitHub 回報問題的使用者：{body}。'


def js_string(s):
    return json.dumps(s, ensure_ascii=False)


def main():
    repo = sys.argv[1] if len(sys.argv) > 1 else os.environ.get('GITHUB_REPOSITORY', 'Hikari-Tsai/karaoke-battle')
    owner = repo.split('/')[0]
    people = reporters(fetch_issues(repo, os.environ.get('GH_TOKEN') or os.environ.get('GITHUB_TOKEN')), owner)
    hidden = '' if people else ' hidden'

    page = open(INDEX, encoding='utf-8').read()
    pattern = re.compile(r'<p class="section-lead thx-issues" data-i18n="thx\.issues"[^>]*>.*?</p>', re.S)
    if not pattern.search(page):
        sys.exit('thx.issues paragraph not found in site/index.html')
    zh = render(people, 'zh') if people else ''
    page = pattern.sub(lambda _: f'<p class="section-lead thx-issues" data-i18n="thx.issues"{hidden}>{zh}</p>', page, count=1)
    open(INDEX, 'w', encoding='utf-8').write(page)

    js = open(I18N, encoding='utf-8').read()
    lines = js.split('\n')
    seen = []
    for k, line in enumerate(lines):
        if line.lstrip().startswith('"thx.issues":'):
            # The English dictionary comes before the Japanese one.
            lang = 'en' if not seen else 'ja'
            indent = line[: len(line) - len(line.lstrip())]
            lines[k] = f'{indent}"thx.issues": {js_string(render(people, lang) if people else "")},'
            seen.append(lang)
    if seen != ['en', 'ja']:
        sys.exit(f'expected thx.issues in en and ja of site/i18n.js, found {seen}')
    open(I18N, 'w', encoding='utf-8').write('\n'.join(lines))

    print(f'{len(people)} reporter(s): ' + ', '.join(f'{login} {[n for n, _, _ in items]}' for login, items in people))


if __name__ == '__main__':
    main()
