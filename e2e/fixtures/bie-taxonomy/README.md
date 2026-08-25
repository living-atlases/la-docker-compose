# bie-index e2e taxonomy fixture

A minimal Darwin Core Archive (Taxon core + VernacularName extension) that
`scripts/e2e-bie-import.sh` unpacks into bie-index's `import.taxonomy.dir` so the
`taxonomy-all` step has something to import.

## Why it exists

Nothing in the deploy chain ever put taxonomy into the bie index. The collections are
created (`roles/la-compose/tasks/init-solr.yml`) and bie-index is wired to them, but the
import is a manual action in ALA's operation, so on a generated stack the index stayed
empty — and every check we had reported green over it, because
`/search?q=Acacia` on an empty index answers `200` with
`{"searchResults":{"totalRecords":0,…}}`. See living-atlases/la-toolkit#28.

## Contents

| File | Rows | Notes |
|---|---|---|
| `taxon.txt` | 41 | 2 kingdoms down to species, `ATLAS_*` ids |
| `vernacularname.txt` | 12 | `en` and `es`, `isPreferredName` set |
| `meta.xml` | — | core rowType `dwc:Taxon`, extension `gbif:VernacularName` |
| `eml.xml` | — | title only; it is the `defaultDatasetName` |

The eight species match the occurrence fixture in `../dr-test`, so a record found in
biocache has a species page in bie. `Acacia dealbata`, `Acacia decurrens` and
`Eucalyptus globulus` are the names the existing gatus and Cypress probes query for,
which is what turns those probes from shape checks into data checks.

## Keep it small

`denormalise` and `link-identifiers` both walk the entire index — the latter issues up to
three Solr queries per document. At this size that is seconds; a real checklist would make
it hours. If you need a realistic corpus, point `BIE_DWCA_DIR` at it instead of growing
this one.
