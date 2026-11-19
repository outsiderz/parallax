#!/usr/bin/env python3
"""Discover exact SDK and EFI image filenames from the official OpenWrt directory listing.

No guessed gcc/musl/compiler suffixes. Only a release/target explicitly supplied by CI.
"""
import argparse
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlparse
import re
import sys


class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            url = dict(attrs).get("href", "")
            self.links.append(Path(unquote(urlparse(url).path)).name)


def find(links, expression, label):
    found = sorted(set(x for x in links if re.fullmatch(expression, x)))
    if len(found) != 1:
        raise SystemExit(f"Expected exactly one {label}, found: {found}")
    return found[0]


def main():
    a = argparse.ArgumentParser()
    a.add_argument("--html", required=True)
    a.add_argument("--version", required=True)
    a.add_argument("--output", required=True)
    ns = a.parse_args()
    if not re.fullmatch(r"25\.12\.\d+", ns.version):
        raise SystemExit("Only pinned OpenWrt 25.12.x releases are supported")
    parser = Links()
    parser.feed(Path(ns.html).read_text())
    prefix = re.escape(ns.version)
    sdk = find(parser.links,
               rf"openwrt-sdk-{prefix}-x86-64_[A-Za-z0-9_.+-]+\.Linux-x86_64\.tar\.zst",
               "SDK archive")
    image = find(parser.links,
                 rf"openwrt-{prefix}-x86-64-generic-ext4-combined-efi\.img\.gz",
                 "combined-efi image")
    output = f"SDK_FILE={sdk}\nIMAGE_FILE={image}\n"
    Path(ns.output).write_text(output)
    print(output, end="")


if __name__ == "__main__":
    main()
