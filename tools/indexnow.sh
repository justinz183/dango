#!/bin/sh
# Tells search engines that support IndexNow (Bing, Yandex, Naver, Seznam…; ChatGPT search and
# Copilot use Bing's index) that dangoai.org's pages changed: every URL in the deployed sitemap.
# Run after a deploy:  tools/indexnow.sh
# The key is the one file named <32 hex>.txt in site/ (published at https://dangoai.org/<key>.txt,
# which proves the site is ours). Google does not take IndexNow; it reads sitemap.xml.
set -eu
cd "$(dirname "$0")/.."
key=$(ls site | sed -n 's/^\([0-9a-f]\{32\}\)\.txt$/\1/p' | head -1)
[ -n "$key" ] || { echo "no IndexNow key file in site/" >&2; exit 1; }
urls=$(curl -fsS https://dangoai.org/sitemap.xml | sed -n 's:.*<loc>\(.*\)</loc>.*:\1:p')
[ -n "$urls" ] || { echo "no URLs in the live sitemap" >&2; exit 1; }
list=$(printf '%s\n' "$urls" | sed 's/.*/"&"/' | paste -sd, -)
body="{\"host\":\"dangoai.org\",\"key\":\"$key\",\"keyLocation\":\"https://dangoai.org/$key.txt\",\"urlList\":[$list]}"
printf 'IndexNow: %s URLs → ' "$(printf '%s\n' "$urls" | wc -l | tr -d ' ')"
curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://api.indexnow.org/indexnow -H 'Content-Type: application/json; charset=utf-8' --data "$body"
# 200 or 202 = accepted (202: key not checked yet); 403 = key file not found; 422 = URLs not on this host.
