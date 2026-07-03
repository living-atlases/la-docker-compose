# biocache SOLR configset — pinned `schema.xml` cache

`schema.xml` here is the biocache occurrence-index SOLR schema. It replaces ala-install's
legacy v2 snake_case schema (`solrcloud_config/templates/biocache_schema_docvalues.xml`),
which no longer matches the deployed **biocache-service 3.8.1 + la-pipelines 3.2.22** → SOLR
**400** on occurrence search (`sort=first_loaded_date` → `firstLoadedDate` not found;
`qc=-_nest_parent_:*` → undefined field `_nest_parent_`).

## Pin (source of truth)

The schema is **pinned to an immutable upstream commit** and **sha256-verified at generate
time** — it is no longer a copy that silently drifts. The pin lives in
`roles/la-compose/vars/main.yml`:

| var | value |
|---|---|
| `biocache_solr_schema_repo`   | `AtlasOfLivingAustralia/pipelines` |
| `biocache_solr_schema_ref`    | `ede867d7a0b46270c9821dd5b7ac864def9f1559` |
| `biocache_solr_schema_path`   | `livingatlas/solr/conf/managed-schema` |
| `biocache_solr_schema_sha256` | `251d68de329ed9c29c01f111f60034081d662c4b70e70d48451930b590eba2a6` |

Schema version 1.5; camelCase fields (`firstLoadedDate`, …) + nested-doc fields (`_root_`,
`_nest_parent_`, `_nest_path_`). Matching solrconfig is `luceneMatchVersion` **8.4.1** → Solr 8
native; `la_solr = solr:8.9.0` (same as gbif.es prod).

`generate-compose.yml` fetches the pinned URL with `get_url … checksum:` (fails loudly on any
mismatch / bad ref). **The `schema.xml` in this directory is the offline cache/fallback** used
when there is no network egress; its sha256 must equal `biocache_solr_schema_sha256`, which is
enforced by `scripts/validate-config-gen.sh` (Check 0).

## Scope

Only `schema.xml` is overridden. `solrconfig.xml` + resources (`synonyms.txt`, `stopwords.txt`,
`protwords.txt`, `elevate.xml`) still come from ala-install's `biocache/conf` (copied by
`generate-compose.yml` → "Copy Solr configuration files"), proven on Solr 8.9. No explicit
`schemaFactory` → Solr's default `ManagedIndexSchemaFactory` reads `schema.xml` on a **fresh**
collection CREATE and converts it to `managed-schema`. **Applying a *changed* schema therefore
needs the biocache collection recreated + a REINDEX** (la-pipelines/Airflow), not just an
upconfig+reload — that apply/reindex step is **out of scope** of the schema pin and is tracked
separately in `TODO.org` `[hub bug]`.

## Update procedure (moving the pin)

1. Pick the new upstream commit `REF` (an immutable SHA, not a branch name).
2. Download the schema at that commit and overwrite this cache:
   ```
   curl -fsSL \
     "https://raw.githubusercontent.com/AtlasOfLivingAustralia/pipelines/${REF}/livingatlas/solr/conf/managed-schema" \
     -o roles/la-compose/files/solr/biocache/conf/schema.xml
   ```
3. Compute the new hash: `sha256sum roles/la-compose/files/solr/biocache/conf/schema.xml`.
4. In `roles/la-compose/vars/main.yml`, update **both** `biocache_solr_schema_ref` and
   `biocache_solr_schema_sha256` in the same commit as the refreshed cache file above.
5. `bash scripts/validate-config-gen.sh` (Check 0 must pass) and commit all together.

## References

- GH issue: <https://github.com/living-atlases/la-docker-compose/issues/2>
- gbif/pipelines#1038 — `livingatlas/solr/conf` outdated vs helm-charts.
- `AtlasOfLivingAustralia/pipelines@feature/ala-upgrade` — current biocache SOLR schema branch.
