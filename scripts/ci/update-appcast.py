#!/usr/bin/env python3
"""Adds one release to Cida's Sparkle appcast (Design/spec/updates.md).

The new item goes first. An item with the same build number is replaced, so publishing a
release candidate and then the release from one commit, or rerunning a job, leaves one item.
Release candidates carry the beta channel; releases carry none. The release notes are the
given lines as an HTML list.

    update-appcast.py --appcast current.xml --output appcast.xml --version 1.1.0 --build 140 \
        --url https://.../Cida-1.1.0-140.zip --length 19000000 --signature <EdDSA> \
        [--channel beta] [--notes notes.txt]

A missing --appcast file starts a new feed. Signing the feed is left to Sparkle's sign_update.
"""

import argparse
import email.utils
import html
import pathlib
import sys
import xml.etree.ElementTree as ElementTree

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ElementTree.register_namespace("sparkle", SPARKLE)

MINIMUM_SYSTEM_VERSION = "15.0"
FEED_TITLE = "辞达"
FEED_LINK = "https://cida-releases.xuanwo.io/appcast.xml"


def sparkle(name):
    return f"{{{SPARKLE}}}{name}"


def parse_arguments(arguments):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--appcast", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--length", required=True, type=int)
    parser.add_argument("--signature", required=True)
    parser.add_argument("--channel", choices=("beta",))
    parser.add_argument("--notes", type=pathlib.Path)
    parser.add_argument("--published", help="RFC 2822 date; defaults to now")
    return parser.parse_args(arguments)


def load_channel(path):
    if path.exists():
        tree = ElementTree.parse(path)
        channel = tree.getroot().find("channel")
        if channel is None:
            raise SystemExit(f"{path} has no <channel>")
        return tree, channel
    root = ElementTree.Element("rss", {"version": "2.0"})
    channel = ElementTree.SubElement(root, "channel")
    ElementTree.SubElement(channel, "title").text = FEED_TITLE
    ElementTree.SubElement(channel, "link").text = FEED_LINK
    return ElementTree.ElementTree(root), channel


def notes_html(lines):
    items = [line.strip() for line in lines if line.strip()]
    if not items:
        return None
    return "<ul>" + "".join(f"<li>{html.escape(item)}</li>" for item in items) + "</ul>"


def make_item(arguments, notes):
    item = ElementTree.Element("item")
    ElementTree.SubElement(item, "title").text = arguments.version
    ElementTree.SubElement(item, "pubDate").text = arguments.published or email.utils.formatdate(
        usegmt=True
    )
    ElementTree.SubElement(item, sparkle("version")).text = arguments.build
    ElementTree.SubElement(item, sparkle("shortVersionString")).text = arguments.version
    ElementTree.SubElement(item, sparkle("minimumSystemVersion")).text = MINIMUM_SYSTEM_VERSION
    if arguments.channel:
        ElementTree.SubElement(item, sparkle("channel")).text = arguments.channel
    if notes:
        ElementTree.SubElement(item, "description").text = notes
    ElementTree.SubElement(
        item,
        "enclosure",
        {
            "url": arguments.url,
            "length": str(arguments.length),
            "type": "application/octet-stream",
            sparkle("edSignature"): arguments.signature,
        },
    )
    return item


def main(arguments):
    arguments = parse_arguments(arguments)
    tree, channel = load_channel(arguments.appcast)
    for item in channel.findall("item"):
        if item.findtext(sparkle("version")) == arguments.build:
            channel.remove(item)
    notes = notes_html(arguments.notes.read_text(encoding="utf-8").splitlines()) if arguments.notes else None
    first_item = next(
        (index for index, child in enumerate(list(channel)) if child.tag == "item"), len(channel)
    )
    channel.insert(first_item, make_item(arguments, notes))
    ElementTree.indent(tree, space="  ")
    arguments.output.write_bytes(
        ElementTree.tostring(tree.getroot(), encoding="utf-8", xml_declaration=True) + b"\n"
    )


if __name__ == "__main__":
    main(sys.argv[1:])
