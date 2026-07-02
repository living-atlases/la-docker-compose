# biocache SOLR configset — vendored `schema.xml` (STOPGAP)

`schema.xml` here is the biocache occurrence-index SOLR schema, **vendored** from the
current ALA pipelines branch. It replaces ala-install's legacy v2 snake_case schema
(`solrcloud_config/templates/biocache_schema_docvalues.xml`), which no longer matches
the deployed **biocache-service 3.8.1 + la-pipelines 3.2.22** → SOLR **400** on
occurrence search (`sort=first_loaded_date` → `firstLoadedDate` not found;
`qc=-_nest_parent_:*` → undefined field `_nest_parent_`).

**Source** (2026-07-02):
`https://raw.githubusercontent.com/AtlasOfLivingAustralia/pipelines/feature/ala-upgrade/livingatlas/solr/conf/managed-schema`
→ renamed to `schema.xml`. Schema version 1.5; camelCase fields (`firstLoadedDate`, …)
+ nested-doc fields (`_root_`, `_nest_parent_`, `_nest_path_`). Its matching solrconfig
is `luceneMatchVersion` **8.4.1** → Solr 8 native; `la_solr = solr:8.9.0` (same as
gbif.es prod).

**Scope:** only `schema.xml` is overridden. `solrconfig.xml` + resources (`synonyms.txt`,
`stopwords.txt`, `protwords.txt`, `elevate.xml`) still come from ala-install's
`biocache/conf` (copied by `generate-compose.yml` → "Copy Solr configuration files"),
proven on Solr 8.9. No explicit `schemaFactory` → Solr's default
`ManagedIndexSchemaFactory` reads `schema.xml` on a **fresh** collection CREATE and
converts it to `managed-schema`; applying a changed schema therefore needs the biocache
collection **recreated + a REINDEX** (la-pipelines/Airflow), not just an upconfig+reload.

**STOPGAP** — see `TODO.org` → `[schema] biocache SOLR schema DESFASADO` for the proper
fix (source the configset from the deployed pipelines version instead of a vendored copy
that drifts). Refs: gbif/pipelines#1038; `AtlasOfLivingAustralia/pipelines@feature/ala-upgrade`.
