#!/bin/sh
# Rebuild the hosted index.html from the app source (../enivel/index.html) with a full HTML head.
# The claude.ai preview adds the viewport tag itself; GitHub Pages needs it in the file.
python3 - "$1" <<'PY'
import sys
src=sys.argv[1] if len(sys.argv)>1 and sys.argv[1] else '../enivel/index.html'
s=open(src).read()
head='<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><meta name="description" content="Enivel: verified scholar transport for South Africa."><style>:root{padding-top:env(safe-area-inset-top,0px);padding-bottom:env(safe-area-inset-bottom,0px)}body{margin:0;font:15px/1.5 system-ui,sans-serif}img{max-width:100%}[hidden]{display:none!important}</style></head><body>\n'
open('index.html','w').write(head+s+'\n</body></html>\n')
PY
