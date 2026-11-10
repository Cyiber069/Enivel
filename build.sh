#!/bin/sh
# Build the hosted index.html from the app source (default ../enivel/index.html):
# adds a full HTML head (viewport etc.) and removes the preview-only admin password hash.
python3 - "${1:-../enivel/index.html}" <<'PY'
import sys,re
s=open(sys.argv[1]).read()
s=re.sub(r"const ADMIN_HASH='[0-9a-f]{64}';","const ADMIN_HASH='';",s)
head='<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><meta name="description" content="Enivel: verified scholar transport for South Africa."><style>:root{padding-top:env(safe-area-inset-top,0px);padding-bottom:env(safe-area-inset-bottom,0px)}body{margin:0;font:15px/1.5 system-ui,sans-serif}img{max-width:100%}[hidden]{display:none!important}</style></head><body>\n'
open('index.html','w').write(head+s+'\n</body></html>\n')
PY
grep -c "ADMIN_HASH=''" index.html
# Google / WhatsApp-readable homepage, a page per school, sitemap and robots.txt
python3 tools/seo.py
# shrink the file phones download (needs Node; installs the minifier the first time)
if command -v node >/dev/null 2>&1; then
  [ -d node_modules/html-minifier-terser ] || npm install --no-audit --no-fund >/dev/null 2>&1
  node tools/minify.mjs index.html index.html || echo "minify skipped"
fi
