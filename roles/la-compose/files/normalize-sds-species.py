#!/usr/bin/env python3
"""Rewrite display names into ids in the sensitive species data.

ALA's sensitive-species-data.xml mixes both forms in the `category` and `zone`
attributes of <conservationInstance>: most rows carry an id ("CR", "NSW"), but
some carry the display name of that same entry ("Critically Endangered", "New
South Wales"). The sensitive-data-service resolves them by id only
(SensitivityZoneFactory.getZone does zones.get(key.toUpperCase())), stores a null
for the rest, and dies on the first comparison:

    java.lang.NullPointerException
        at au.org.ala.sds.model.SensitivityInstance.equals(SensitivityInstance.java:89)
        at au.org.ala.sds.model.SensitiveTaxonStore.verifyAndInitialiseSpeciesList

so the whole service crash-loops on "Unable to initialise searcher: null".

Only values that are not already an id and that match the name of a defined
entry are rewritten - the mapping is taken from the categories and zones files
themselves, never hardcoded. Anything left unresolved is an error: the service
would crash-loop on it, which is far harder to read than a failed play.

Usage: normalize-sds-species.py <species.xml> <categories.xml> <zones.xml>
"""

import re
import sys
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape, unescape

INSTANCE_RE = re.compile(r"<conservationInstance\b[^>]*/?>")
ATTR_RE = re.compile(r'\b(category|zone)="([^"]*)"')


def index(path):
    """Return (ids, name -> id) for a categories or zones file."""
    root = ET.parse(path).getroot()
    ids = {}
    names = {}
    for element in root:
        entry_id = element.get("id")
        if entry_id is None:
            continue
        ids[entry_id.upper()] = entry_id
        name = element.get("name")
        if name:
            names.setdefault(name.upper(), entry_id)
    return ids, names


def main(species_path, categories_path, zones_path):
    lookup = {
        "category": index(categories_path),
        "zone": index(zones_path),
    }

    with open(species_path, encoding="utf-8") as handle:
        original = handle.read()

    rewrites = 0
    unresolved = {}

    def fix_attributes(instance):
        def fix(match):
            nonlocal rewrites
            attribute, raw = match.group(1), match.group(2)
            value = unescape(raw)
            ids, names = lookup[attribute]
            if value.upper() in ids:
                return match.group(0)
            entry_id = names.get(value.upper())
            if entry_id is None:
                unresolved.setdefault(attribute, set()).add(value)
                return match.group(0)
            rewrites += 1
            return '%s="%s"' % (attribute, escape(entry_id, {'"': "&quot;"}))

        return ATTR_RE.sub(fix, instance)

    normalized = INSTANCE_RE.sub(lambda m: fix_attributes(m.group(0)), original)

    if unresolved:
        for attribute, values in sorted(unresolved.items()):
            print(
                "%s: %s is neither an id nor a name in %s"
                % (
                    species_path,
                    ", ".join(sorted(values)),
                    categories_path if attribute == "category" else zones_path,
                ),
                file=sys.stderr,
            )
        return 2

    if normalized != original:
        with open(species_path, "w", encoding="utf-8") as handle:
            handle.write(normalized)

    print("rewrote %d category/zone references to ids" % rewrites)
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        sys.exit(64)
    sys.exit(main(*sys.argv[1:]))
