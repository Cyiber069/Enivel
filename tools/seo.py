#!/usr/bin/env python3
"""Make enivel.co.za readable without JavaScript (Google, WhatsApp/Facebook link previews).
Run by build.sh after index.html is built:
  - index.html: real <title>, description, canonical, Open Graph / Twitter tags, JSON-LD, and plain-HTML
    homepage content with real links inside <div id="app"> (the app replaces it as soon as it starts);
  - one page per school: school/<slug>.html ("School transport for X") that shows live verified drivers
    and open seats, or a waitlist form, using the same public Supabase functions as the app;
  - schools/index.html + one page per province, sitemap.xml (+ sitemaps/*.xml), robots.txt, .nojekyll.
"""
import json, os, re, html, unicodedata, shutil, datetime
BASE = 'https://enivel.co.za'
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROV = {'GT': 'Gauteng', 'WC': 'Western Cape', 'KZ': 'KwaZulu-Natal', 'EC': 'Eastern Cape', 'LP': 'Limpopo',
        'MP': 'Mpumalanga', 'NW': 'North West', 'FS': 'Free State', 'NC': 'Northern Cape'}
PH = {'P': 'Primary School', 'S': 'Secondary School', 'C': 'Combined School', 'I': 'Intermediate School', 'E': 'Pre-primary', 'O': 'School'}
SCHOOLWORD = re.compile(r'school|skool|college|academy|primary|secondary|high|laerskool|ho[eë]rskool|prep|centre|center|kollege', re.I)
TODAY = datetime.date.today().isoformat()
E = html.escape
EMAIL = 'Enivel000@gmail.com'

def full_name(n, t):
    n = n.strip()
    return n if SCHOOLWORD.search(n) else f"{n} {PH.get((t or 'O')[0], 'School')}"

def slugify(s):
    s = unicodedata.normalize('NFKD', s).encode('ascii', 'ignore').decode().lower()
    return re.sub(r'[^a-z0-9]+', '-', s).strip('-')[:80] or 'school'

def page(title, desc, path, body, extra_head=''):
    return f'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{E(title)}</title><meta name="description" content="{E(desc)}"><link rel="canonical" href="{BASE}{path}">
<meta property="og:title" content="{E(title)}"><meta property="og:description" content="{E(desc)}"><link rel="stylesheet" href="/assets/seo.css">{extra_head}</head><body>
<header class="top"><a class="logo" href="/">Enivel</a><nav><a href="/schools/">Schools</a><a href="/?check=1#check">Check a driver</a><a class="btn" href="/?signup=parent">Get started</a></nav></header>
<main>{body}</main>
<footer><p>Enivel: verified school transport in South Africa. Questions? <a href="mailto:{EMAIL}">{EMAIL}</a></p>
<p><a href="/">Home</a> · <a href="/schools/">All schools</a> · <a href="/?page=privacy">Privacy</a> · <a href="/?page=terms">Terms</a> · <a href="/?page=safety">Safety</a></p></footer></body></html>
'''

def main():
    idx_path = os.path.join(ROOT, 'index.html')
    s = open(idx_path, encoding='utf-8').read()
    data = json.load(open(os.path.join(ROOT, 'schools.json'), encoding='utf-8'))['s']
    # ---------- schools ----------
    seen = {}; schools = []
    for row in data:
        n, t, town, prov = row[0], row[1], row[2], row[3]
        if not n.strip() or prov not in PROV: continue
        fn = full_name(n, t); town1 = (town or '').split(',')[-1].strip() or PROV[prov]
        base = slugify(f'{fn} {town1}'); slug = base; i = 2
        while slug in seen: slug = f'{base}-{i}'; i += 1
        seen[slug] = 1
        schools.append({'name': fn, 'town': (town or '').strip(), 'town1': town1, 'prov': prov, 'slug': slug})
    for d in ['school', 'schools', 'sitemaps', 'assets']:
        p = os.path.join(ROOT, d)
        if d in ('school', 'schools', 'sitemaps') and os.path.isdir(p): shutil.rmtree(p)
        os.makedirs(p, exist_ok=True)
    for a in ('seo.css', 'school.js'):
        shutil.copyfile(os.path.join(ROOT, 'assets-src', a), os.path.join(ROOT, 'assets', a))
    by_prov = {}
    for sc in schools: by_prov.setdefault(sc['prov'], {}).setdefault(sc['town1'], []).append(sc)
    for sc in schools:
        town_list = [x for x in by_prov[sc['prov']][sc['town1']] if x is not sc][:6]
        title = f"School transport for {sc['name']} ({sc['town1']}) | Enivel"
        desc = f"Safe school transport to {sc['name']} in {sc['town'] or sc['town1']}, {PROV[sc['prov']]}. Verified drivers, open seats and live pickup alerts. Join the waitlist if there's no driver yet."
        ld = {"@context": "https://schema.org", "@type": "BreadcrumbList", "itemListElement": [
            {"@type": "ListItem", "position": 1, "name": "Schools", "item": f"{BASE}/schools/"},
            {"@type": "ListItem", "position": 2, "name": PROV[sc['prov']], "item": f"{BASE}/schools/{sc['prov'].lower()}.html"},
            {"@type": "ListItem", "position": 3, "name": sc['name'], "item": f"{BASE}/school/{sc['slug']}.html"}]}
        body = f'''<p class="crumb"><a href="/schools/">Schools</a> › <a href="/schools/{sc['prov'].lower()}.html">{E(PROV[sc['prov']])}</a> › {E(sc['town1'])}</p>
<h1>School transport for {E(sc['name'])}</h1>
<p class="lead">Looking for safe transport to <b>{E(sc['name'])}</b> in {E(sc['town'] or sc['town1'])}? On Enivel every driver's ID, driver's licence, PrDP and police clearance is checked before they can take a child, and you get alerts when your child is picked up, arrives at school and is dropped off.</p>
<section id="live" data-school="{E(sc['name'])}"><h2>Drivers for this school</h2><p class="muted">Loading verified drivers and open seats…</p>
<noscript><p>Open <a href="/?school={E(sc['name'])}">Enivel</a> to see drivers for this school.</p></noscript></section>
<p>Pay monthly in the app: the driver's price plus a 5% Enivel fee. <a class="btn" href="/?signup=parent">Get started, free</a> <a class="btn ghost" href="/?signup=driver">I'm a driver</a></p>
{('<section><h2>Other schools in ' + E(sc['town1']) + '</h2><ul class="cols">' + ''.join(f'<li><a href="/school/{x["slug"]}.html">{E(x["name"])}</a></li>' for x in town_list) + '</ul></section>') if town_list else ''}'''
        extra = f'<script type="application/ld+json">{json.dumps(ld,separators=(",",":"))}</script><script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.49.4/dist/umd/supabase.js" defer></script><script src="/assets/school.js" defer></script>'
        open(os.path.join(ROOT, 'school', sc['slug'] + '.html'), 'w', encoding='utf-8').write(page(title, desc, f"/school/{sc['slug']}.html", body, extra))
    # province pages + index
    for pv, towns in by_prov.items():
        parts = []
        for town in sorted(towns, key=str.lower):
            parts.append(f'<h3>{E(town)}</h3><ul class="cols">' + ''.join(f'<li><a href="/school/{x["slug"]}.html">{E(x["name"])}</a></li>' for x in sorted(towns[town], key=lambda x: x['name'].lower())) + '</ul>')
        n = sum(len(v) for v in towns.values())
        open(os.path.join(ROOT, 'schools', pv.lower() + '.html'), 'w', encoding='utf-8').write(page(
            f'School transport in {PROV[pv]}: {n} schools | Enivel', f'Find verified school transport for {n} schools in {PROV[pv]}, or join the waitlist for your school.',
            f'/schools/{pv.lower()}.html', f'<p class="crumb"><a href="/schools/">Schools</a> › {E(PROV[pv])}</p><h1>School transport in {E(PROV[pv])}</h1><p class="lead">Choose your child\'s school to see verified drivers and open seats, or join the waitlist.</p>' + ''.join(parts)))
    open(os.path.join(ROOT, 'schools', 'index.html'), 'w', encoding='utf-8').write(page(
        'School transport for every school in South Africa | Enivel', 'Find verified school transport by province and school, or join the waitlist for your school.', '/schools/',
        '<h1>Find school transport for your school</h1><p class="lead">Pick your province, then your school.</p><ul class="cols">' +
        ''.join(f'<li><a href="/schools/{pv.lower()}.html">{E(PROV[pv])}</a> ({sum(len(v) for v in by_prov[pv].values())} schools)</li>' for pv in sorted(by_prov, key=lambda k: PROV[k])) + '</ul>'))
    # sitemaps
    urls = [f'{BASE}/', f'{BASE}/schools/'] + [f'{BASE}/schools/{pv.lower()}.html' for pv in by_prov]
    def sm(lst): return '<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n' + ''.join(f'<url><loc>{u}</loc><lastmod>{TODAY}</lastmod></url>\n' for u in lst) + '</urlset>\n'
    open(os.path.join(ROOT, 'sitemaps', 'site.xml'), 'w').write(sm(urls))
    sch_urls = [f"{BASE}/school/{x['slug']}.html" for x in schools]; files = ['site.xml']
    for i in range(0, len(sch_urls), 10000):
        fn = f'schools-{i // 10000 + 1}.xml'; files.append(fn); open(os.path.join(ROOT, 'sitemaps', fn), 'w').write(sm(sch_urls[i:i + 10000]))
    open(os.path.join(ROOT, 'sitemap.xml'), 'w').write('<?xml version="1.0" encoding="UTF-8"?>\n<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n' + ''.join(f'<sitemap><loc>{BASE}/sitemaps/{f}</loc><lastmod>{TODAY}</lastmod></sitemap>\n' for f in files) + '</sitemapindex>\n')
    open(os.path.join(ROOT, 'robots.txt'), 'w').write(f'User-agent: *\nAllow: /\nSitemap: {BASE}/sitemap.xml\n')
    open(os.path.join(ROOT, '.nojekyll'), 'w').write('')
    # ---------- homepage head + static content ----------
    title = 'Enivel | Safe school transport with verified drivers in South Africa'
    desc = "Find safe school transport in South Africa. Every driver's ID, licence, PrDP and police clearance is checked. Live alerts at pickup and drop-off, pay monthly in the app."
    faq = [("How are drivers verified?", "Every driver uploads their SA ID, driver's licence, PrDP, police clearance, vehicle photos, operating licence and insurance. Enivel checks them before a driver can list a route and watches expiry dates afterwards."),
           ("What does it cost?", "You pay the driver's monthly price plus a 5% Enivel fee, shown before you pay. On a R900 route that is R45. No sign-up fee, no contract, cancel any time. Drivers keep their full price."),
           ("Is there a driver for my school?", "Search your school on Enivel. If there is no driver yet, join the waitlist and we will WhatsApp you when a verified driver starts."),
           ("Can I check a driver before I book?", "Yes. Type a driver's full name or number plate under Check a driver to see if they are verified and when their documents expire.")]
    ld = [{"@context": "https://schema.org", "@type": "Organization", "name": "Enivel", "url": BASE + "/", "email": EMAIL, "areaServed": "ZA", "founder": {"@type": "Person", "name": "Kgosi Mosupi"}},
          {"@context": "https://schema.org", "@type": "WebSite", "name": "Enivel", "url": BASE + "/"},
          {"@context": "https://schema.org", "@type": "FAQPage", "mainEntity": [{"@type": "Question", "name": q, "acceptedAnswer": {"@type": "Answer", "text": a}} for q, a in faq]}]
    head = (f'<title>{E(title)}</title><meta name="description" content="{E(desc)}"><link rel="canonical" href="{BASE}/">'
            f'<meta property="og:type" content="website"><meta property="og:site_name" content="Enivel"><meta property="og:title" content="{E(title)}"><meta property="og:description" content="{E(desc)}"><meta property="og:url" content="{BASE}/"><meta property="og:locale" content="en_ZA">'
            f'<meta name="twitter:card" content="summary"><meta name="twitter:title" content="{E(title)}"><meta name="twitter:description" content="{E(desc)}">'
            f'<link rel="alternate" hreflang="en" href="{BASE}/"><link rel="alternate" hreflang="af" href="{BASE}/?lang=af"><link rel="alternate" hreflang="zu" href="{BASE}/?lang=zu">'
            + ''.join(f'<script type="application/ld+json">{json.dumps(x)}</script>' for x in ld))
    s = re.sub(r'<meta name="description" content="[^"]*">', '', s, count=1)
    s = s.replace('<title>Enivel</title>', head, 1)
    top_schools = sorted(schools, key=lambda x: (x['prov'] != 'GT', x['name']))[:0]
    static = f'''<div class="seo-static" style="max-width:720px;margin:0 auto;padding:24px 16px;font:16px/1.55 system-ui,sans-serif">
<h1>Safe school transport with verified drivers</h1>
<p>Book a checked driver for your child's school run in South Africa. Know the moment they are picked up, at school and home again.</p>
<p><a href="/?signup=parent">Get started, free</a> · <a href="/?signup=driver">I'm a driver</a> · <a href="/?login=1">Log in</a></p>
<h2>Is there a driver for my school?</h2><p><a href="/schools/">Find your school</a> to see verified drivers and open seats, or join the waitlist.</p>
<ul>{''.join(f'<li><a href="/schools/{pv.lower()}.html">School transport in {E(PROV[pv])}</a></li>' for pv in sorted(by_prov, key=lambda k: PROV[k]))}</ul>
<h2>Why parents use Enivel</h2><ul><li><b>Verified drivers</b>: ID, driver's licence, PrDP and police clearance checked, documents watched for expiry.</li><li><b>Live alerts</b> when the driver is near, at pickup, at school and at drop-off, with a live map.</li><li><b>Kid Emergency button</b> that sends your child's location to you.</li></ul>
<h2>Honest pricing</h2><p>You pay the driver's monthly price plus a 5% Enivel fee. On a R900 route that is R45. Drivers keep their full price.</p>
<h2>Check a driver</h2><p><a href="/?check=1">Check a driver</a> by full name or number plate to see if they are verified and when their documents expire.</p>
<h2>Questions parents ask</h2>{''.join(f'<h3>{E(q)}</h3><p>{E(a)}</p>' for q, a in faq)}
<h2>Talk to a person</h2><p>Enivel is built in South Africa by founder Kgosi Mosupi. Email <a href="mailto:{EMAIL}">{EMAIL}</a>.</p>
<p><a href="/?page=privacy">Privacy</a> · <a href="/?page=terms">Terms</a> · <a href="/?page=safety">Safety</a> · <a href="/?lang=af">Afrikaans</a> · <a href="/?lang=zu">isiZulu</a></p></div>'''
    s = s.replace('<div class="app" id="app"></div>', '<div class="app" id="app">' + static + '</div>', 1)
    open(idx_path, 'w', encoding='utf-8').write(s)
    print(f'seo: {len(schools)} school pages, {len(by_prov)} provinces, sitemap ok')

if __name__ == '__main__':
    main()
