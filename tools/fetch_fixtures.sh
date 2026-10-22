#!/bin/sh
# Re-download the real API responses used by spec/ (run from anywhere).
cd "$(dirname "$0")/../spec/fixtures" || exit 1
UA="wookieepedia.koplugin/0.1-dev (+https://github.com/koreader/koreader)"
B='https://starwars.fandom.com/api.php?action=parse&redirects=1&disablelimitreport=1&disableeditsection=1&format=json&formatversion=2'
curl -s -A "$UA" "$B&page=Avar_Kriss&section=0&prop=text|properties" -o avar_kriss_intro.json
curl -s -A "$UA" "$B&page=Rey&section=0&prop=text|properties" -o rey_redirect_intro.json
curl -s -A "$UA" "$B&page=Starlight_Beacon&prop=text" -o starlight_beacon_full.json
curl -s -A "$UA" "$B&page=Mace&prop=text|properties" -o mace_disambiguation_full.json
curl -s -A "$UA" "$B&page=Xyzzyqq_Florbnik&section=0&prop=text|properties" -o missing.json
ls -la
