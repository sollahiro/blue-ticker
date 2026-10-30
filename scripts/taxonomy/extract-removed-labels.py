#!/usr/bin/env python3
"""旧版タクソノミの日本語 _lab.xml から、現行版で消えた概念のラベルだけを抜き出す。

使い方:
  python3 scripts/taxonomy/extract-removed-labels.py OLD_lab.xml CURRENT_lab.xml OUT_lab.xml

旧版にあり現行版に無い概念（廃止・改名された科目）の loc / label / labelArc だけを残した
ラベルリンクベースを書き出す。現行版にある概念は含めない（現行ラベルが常に勝つ）。
"""
import sys
import xml.etree.ElementTree as ET

LINK = "http://www.xbrl.org/2003/linkbase"
XLINK = "http://www.w3.org/1999/xlink"


def q(ns, name):
    return f"{{{ns}}}{name}"


def concepts(root):
    names = set()
    for loc in root.iter(q(LINK, "loc")):
        href = loc.get(q(XLINK, "href"), "")
        frag = href.split("#", 1)[-1]
        names.add(frag.split("_", 2)[-1] if frag.count("_") >= 2 else frag)
    return names


def main(old_path, current_path, out_path):
    ET.register_namespace("link", LINK)
    ET.register_namespace("xlink", XLINK)
    ET.register_namespace("xml", "http://www.w3.org/XML/1998/namespace")
    current = concepts(ET.parse(current_path).getroot())
    old_root = ET.parse(old_path).getroot()

    out_root = ET.Element(q(LINK, "linkbase"))
    count = 0
    for link in old_root.iter(q(LINK, "labelLink")):
        keep_locs = {}
        for loc in link.iter(q(LINK, "loc")):
            href = loc.get(q(XLINK, "href"), "")
            frag = href.split("#", 1)[-1]
            concept = frag.split("_", 2)[-1] if frag.count("_") >= 2 else frag
            if concept not in current:
                keep_locs[loc.get(q(XLINK, "label"))] = loc
        if not keep_locs:
            continue
        arcs = [a for a in link.iter(q(LINK, "labelArc")) if a.get(q(XLINK, "from")) in keep_locs]
        keep_labels = {a.get(q(XLINK, "to")) for a in arcs}
        new_link = ET.SubElement(out_root, q(LINK, "labelLink"), dict(link.attrib))
        for loc in keep_locs.values():
            new_link.append(loc)
        for label in link.iter(q(LINK, "label")):
            if label.get(q(XLINK, "label")) in keep_labels:
                new_link.append(label)
        for arc in arcs:
            new_link.append(arc)
        count += len(keep_locs)
    ET.ElementTree(out_root).write(out_path, encoding="utf-8", xml_declaration=True)
    print(f"{out_path}: {count} concepts")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
