#!/bin/sh
# How many times DANGO has been downloaded, from GitHub's own counts (the app itself sends
# nothing; 2026-11-10, user: 「app还是不往外发吧」「就统计下载次数就好」).
#
#   tools/downloads.sh
#
# Per release and in all: Mac by download (the dmg), Mac by command line (install.sh fetches the
# zip), Windows (the installer, by download and by PowerShell alike: one file, so one count).
# GitHub counts every download, re-downloads and bots included; there are no unique users.
set -eu
gh api --paginate repos/justinz183/dango/releases --jq '.[] | .tag_name as $t | .assets[] | [$t, .name, .download_count] | @tsv' |
awk -F'\t' '
  $2 == "Dango-macOS.dmg"                { mac[$1] += $3; tm += $3; seen[$1] = 1 }
  $2 ~ /^Dango-.*\.zip$/                 { cli[$1] += $3; tc += $3; seen[$1] = 1 }
  $2 == "Dango-Windows-x64-setup.exe"    { win[$1] += $3; tw += $3; seen[$1] = 1 }
  END {
    printf "%-10s %12s %12s %12s %8s\n", "release", "Mac (dmg)", "Mac (curl)", "Windows", "total"
    for (r in seen) printf "%-10s %12d %12d %12d %8d\n", r, mac[r], cli[r], win[r], mac[r] + cli[r] + win[r]
    printf "%-10s %12d %12d %12d %8d\n", "all", tm, tc, tw, tm + tc + tw
  }'
