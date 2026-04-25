# Graph Report - .  (2026-04-22)

## Corpus Check
- 151 files · ~108,842 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 318 nodes · 378 edges · 29 communities detected
- Extraction: 78% EXTRACTED · 22% INFERRED · 0% AMBIGUOUS · INFERRED: 82 edges (avg confidence: 0.82)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- [[_COMMUNITY_Ala|Ala]]
- [[_COMMUNITY_Ansible|Ansible]]
- [[_COMMUNITY_Vocab|Vocab]]
- [[_COMMUNITY_Ala|Ala]]
- [[_COMMUNITY_Biocache|Biocache]]
- [[_COMMUNITY_Config|Config]]
- [[_COMMUNITY_Biocachecli|Biocachecli]]
- [[_COMMUNITY_Es|Es]]
- [[_COMMUNITY_Dwc|Dwc]]
- [[_COMMUNITY_Custom|Custom]]
- [[_COMMUNITY_Solr4|Solr4]]
- [[_COMMUNITY_Bootstrap|Bootstrap]]
- [[_COMMUNITY_Bootstrap|Bootstrap]]
- [[_COMMUNITY_Biocache3|Biocache3]]
- [[_COMMUNITY_Elasticsearch|Elasticsearch]]
- [[_COMMUNITY_Db|Db]]
- [[_COMMUNITY_Create|Create]]
- [[_COMMUNITY_Jenkins|Jenkins]]
- [[_COMMUNITY_Elasticsearch|Elasticsearch]]
- [[_COMMUNITY_Web2Py|Web2Py]]
- [[_COMMUNITY_Create|Create]]
- [[_COMMUNITY_Demo|Demo]]
- [[_COMMUNITY_Branding|Branding]]
- [[_COMMUNITY_Cesp2018|Cesp2018]]
- [[_COMMUNITY_Volunteer|Volunteer]]
- [[_COMMUNITY_Elasticsearch|Elasticsearch]]
- [[_COMMUNITY_Hadoop|Hadoop]]
- [[_COMMUNITY_Ala|Ala]]
- [[_COMMUNITY_Demo|Demo]]

## God Nodes (most connected - your core abstractions)
1. `Demo Landing Page (index.html)` - 16 edges
2. `Darwin Core Vocabulary` - 14 edges
3. `la-docker-compose Plan Document` - 13 edges
4. `la-docker-compose Overview` - 9 edges
5. `la-docker-compose Repository` - 9 edges
6. `Darwin Core (DwC) Standard` - 9 edges
7. `FilterModule.filters Method` - 8 edges
8. `Elasticsearch Serverspec Helper (spec_helper.rb)` - 8 edges
9. `ala-install Repository (ALA Ansible Roles)` - 8 edges
10. `generator-living-atlas (Yeoman/Node.js Inventory Factory)` - 8 edges

## Surprising Connections (you probably didn't know these)
- `BUILD_90_COMPLETION_SUMMARY Document` --references--> `create_local_inventory.py Script`  [INFERRED]
  BUILD_90_COMPLETION_SUMMARY.md → scripts/create_local_inventory.py
- `la-docker-compose Overview` --references--> `Cassandra 3 Schema for Biocache (occ keyspace)`  [INFERRED]
  la-docker-compose-overview.md → ala-install/ansible/roles/biocache-db/files/cassandra/cassandra3-schema.txt
- `la-docker-compose Overview` --references--> `Cassandra occ Keyspace (Biocache Occurrence Data)`  [INFERRED]
  la-docker-compose-overview.md → ala-install/ansible/roles/biocache-db/files/cassandra/cassandra3-schema.txt
- `UID/GID 1000 Container File Ownership Fix` --rationale_for--> `la-docker-images Repository`  [EXTRACTED]
  UID_GID_FIX_STATUS.md → la-docker-compose-overview.md
- `validate-ansible.sh Script (yamllint + ansible-lint)` --references--> `la-docker-compose Repository`  [INFERRED]
  VALIDATION.md → README.md

## Hyperedges (group relationships)
- **Elasticsearch Custom Filter Plugin Functions** — elasticsearch_modify_list, elasticsearch_append_to_list, elasticsearch_array_to_str, elasticsearch_extract_role_users, elasticsearch_remove_reserved, elasticsearch_filter_reserved, elasticsearch_filename, elasticsearch_filters_method [EXTRACTED 1.00]
- **Elasticsearch Serverspec Integration Test Suite** — es_integration_issue_test, es_integration_oss, es_integration_xpack, es_integration_xpack_upgrade, es_integration_oss_upgrade, es_integration_oss_to_xpack_upgrade, es_spec_helper, es_shared_spec, es_oss_spec, es_oss_upgrade_spec, es_xpack_upgrade_spec, es_issue_test_spec, es_oss_to_xpack_upgrade_spec [INFERRED 0.85]
- **Local Inventory Generator Components** — scripts_create_local_inventory, create_inventory_generate_hosts_ini, create_inventory_group_mapping, create_inventory_services_dev, create_inventory_services_full [EXTRACTED 1.00]
- **web2py GitHub Authentication Components** — web2py_db_py, web2py_github_account, web2py_github_account_init, web2py_github_account_get_user [EXTRACTED 1.00]

## Communities

### Community 0 - "Ala"
Cohesion: 0.11
Nodes (32): AGENTS.md - AI Agent Guidelines for Ansible Development, ALA Installation Scripts README, ala-install Repository (ALA Ansible Roles), Build #83 CAS Configuration Directory Fix, Cassandra 3 Schema for Biocache (occ keyspace), Cassandra occ Keyspace (Biocache Occurrence Data), Dev-Overlay Pattern (Local + Remote Portal Mix), diagnose-failure.sh Script (+24 more)

### Community 1 - "Ansible"
Cohesion: 0.1
Nodes (26): Ansible Unsafe Dictionary Access Pattern (Direct [] Access), Ansible Evaluation Order: loop before when (Root Cause Pattern), Builds #87-89 Crash Root Cause & Fix, Build #90 Fix Phase 2b: Service Variable Pre-loading, Build #90 Root Cause Analysis, Build #91 Failure Root Cause Analysis, Build #92 Launch Summary, Build #94 Failure & Fix Analysis (+18 more)

### Community 2 - "Vocab"
Cohesion: 0.15
Nodes (24): biocache-cli Ansible Role, Darwin Core (DwC) Standard, Basis of Record Vocabulary, Countries Vocabulary, Country Centre Points Vocabulary, CRS EPSG Codes Vocabulary, Date Precision Vocabulary, Geodetic Datums Vocabulary (+16 more)

### Community 3 - "Ala"
Cohesion: 0.14
Nodes (23): ALA-Install Ansible Scripts, ALA Lucene Name Index, BIE (Species Pages / Biodiversity Information Explorer), Biocache3 DB Cassandra3 Schema, Biocache3 DB Cassandra Schema (legacy), Biocache DB Cassandra Schema (v1), Biocache Hub (Occurrence Search UI), Biocache Web Services (+15 more)

### Community 4 - "Biocache"
Cohesion: 0.11
Nodes (22): Biocache Download CSDM Email Template, Biocache Download DOI Email Template, Biocache Download DOI README Template, Biocache Download Email Template, Biocache Download README Template, Biocache Service Ansible Role, Datadog Role Changelog, Datadog Role Contributing Guide (+14 more)

### Community 5 - "Config"
Cohesion: 0.23
Nodes (15): BIE Solr Index (Species/Taxonomy Search Index), Solr Admin Extra HTML, ISO Latin1 Accent Mapping, Protected Words Configuration, Spellings Configuration, Stopwords Configuration, Synonyms Configuration, Sandbox Index HTML Template (+7 more)

### Community 6 - "Biocachecli"
Cohesion: 0.17
Nodes (15): Biocache-CLI SolrCloud Protected Words, Biocache-CLI Ansible Role, Biocache-CLI SolrCloud Template Configuration, Biocache-CLI SolrCloud Spellings, Biocache-CLI SolrCloud Stopwords, Biocache-CLI SolrCloud Synonyms, Solr4 Biocache Admin Extra HTML, Solr4 Biocache Admin Menu Bottom HTML (+7 more)

### Community 7 - "Es"
Cohesion: 0.15
Nodes (14): ES Integration: issue-test default_spec.rb, ES Integration: oss default_spec.rb, ES Integration: oss-to-xpack-upgrade default_spec.rb, ES Integration: oss-upgrade default_spec.rb, ES Integration: xpack default_spec.rb, ES Integration: xpack-upgrade default_spec.rb, Elasticsearch Issue Test Spec, Elasticsearch OSS Spec (+6 more)

### Community 8 - "Dwc"
Cohesion: 0.14
Nodes (14): DwC: basisOfRecord, DwC: decimalLatitude, DwC: decimalLongitude, DwC: establishmentMeans, DwC: eventDate, DwC: kingdom, DwC: occurrenceID, DwC: recordedBy (+6 more)

### Community 9 - "Custom"
Cohesion: 0.17
Nodes (4): FilterModule, modify_list(), Perform a `re.sub` on every item in the list, object

### Community 10 - "Solr4"
Cohesion: 0.17
Nodes (12): Oznome Demo Ansible Role, Australian State Emblems Vocabulary, Solr4 BIE Admin Extra HTML, Solr4 BIE Admin Menu Bottom HTML, Solr4 BIE Admin Menu Top HTML, Solr4 BIE-specific Stopwords, Solr4 BIE Index Configuration, Solr4 BIE ISOLatin1 Accent Mapping (+4 more)

### Community 11 - "Bootstrap"
Cohesion: 0.22
Nodes (2): clearMenus(), getParent()

### Community 12 - "Bootstrap"
Cohesion: 0.22
Nodes (2): clearMenus(), getParent()

### Community 13 - "Biocache3"
Cohesion: 0.29
Nodes (10): Atlas of Living Australia (ALA), BCCVL (Biodiversity and Climate Change Virtual Laboratory), Biocache3 Download CSDM Email Template, Biocache3 Download DOI Email Template, Biocache3 Download DOI Readme Template, Biocache3 Download Email Template, Biocache3 Download Readme Template, DOI (Digital Object Identifier) for Downloads (+2 more)

### Community 14 - "Elasticsearch"
Cohesion: 0.22
Nodes (9): append_to_list Function, array_to_str Function, extract_role_users Function, filename Function, Ansible Elasticsearch FilterModule, filter_reserved Function, FilterModule.filters Method, modify_list Function (+1 more)

### Community 15 - "Db"
Cohesion: 0.29
Nodes (4): GitHubAccount, OAuth impl for GitHub, Returns the user using the GitHub User API., OAuthAccount

### Community 16 - "Create"
Cohesion: 0.53
Nodes (6): BUILD_90_COMPLETION_SUMMARY Document, generate_hosts_ini Function, GROUP_MAPPING Variable, SERVICES_DEV Variable, SERVICES_FULL Variable, create_local_inventory.py Script

### Community 17 - "Jenkins"
Cohesion: 0.33
Nodes (6): csvtotable (CSV to HTML Table Tool), Jenkins AnsiColor Plugin, Jenkins Node and Label Parameter Plugin, Jenkins CI/CD Service, Pipelines Jenkins Ansible Role, Pipelines Validation Report

### Community 18 - "Elasticsearch"
Cohesion: 0.4
Nodes (6): Ansible Elasticsearch Role (elastic.elasticsearch), Elasticsearch Ansible Role CHANGELOG, Elasticsearch Multi-Instance Documentation, Elasticsearch (7.x/6.x), Elasticsearch X-Pack Features, KitchenCI Testing Framework

### Community 19 - "Web2Py"
Cohesion: 0.4
Nodes (5): OIDC Keys Add SQL (add-key.js), web2pyApps db.py, GitHubAccount Class (db.py), GitHubAccount.get_user Method, GitHubAccount.__init__ Method

### Community 20 - "Create"
Cohesion: 0.67
Nodes (2): generate_hosts_ini(), Generate hosts.ini content from services dict

### Community 21 - "Demo"
Cohesion: 0.67
Nodes (3): Demo Application JS, Demo Bootstrap JS, Demo Bootstrap Min JS

### Community 22 - "Branding"
Cohesion: 1.0
Nodes (3): branding-init Container (Migrated to docker buildx bake), Docker Buildx Migration Guide for Init Containers, docker buildx bake Pattern for Init Containers

### Community 23 - "Cesp2018"
Cohesion: 0.67
Nodes (3): GBIF CESP 2018 Demo Documentation, GBIF Backbone Taxonomy Dataset, TDWG 2017 Demo Documentation

### Community 24 - "Volunteer"
Cohesion: 0.67
Nodes (3): Volunteer Portal 403 Forbidden Error Page, Volunteer Portal 503 Service Unavailable Error Page, Volunteer Portal Ansible Role

### Community 25 - "Elasticsearch"
Cohesion: 1.0
Nodes (3): Elasticsearch Ansible Role, Solr4 (Legacy Search System), SolrCloud (Modern Search System)

### Community 28 - "Hadoop"
Cohesion: 1.0
Nodes (2): Hadoop Molecule Test (test_default.py), test_hosts_file Function (test_default.py)

### Community 43 - "Ala"
Cohesion: 1.0
Nodes (1): ALA Install Ansible README (Groovy skeleton scripts)

### Community 44 - "Demo"
Cohesion: 1.0
Nodes (1): Demo Navigation Bar (Species, Lists, Collections, Occurrences)

## Knowledge Gaps
- **98 isolated node(s):** `Perform a `re.sub` on every item in the list`, `OAuth impl for GitHub`, `Returns the user using the GitHub User API.`, `Generate hosts.ini content from services dict`, `Demo Application JS` (+93 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **Thin community `Bootstrap`** (10 nodes): `bootstrap.min.js`, `clearMenus()`, `complete()`, `getParent()`, `getTargetFromTrigger()`, `next()`, `Plugin()`, `removeElement()`, `ScrollSpy()`, `transitionEnd()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Bootstrap`** (10 nodes): `bootstrap.js`, `clearMenus()`, `complete()`, `getParent()`, `getTargetFromTrigger()`, `next()`, `Plugin()`, `removeElement()`, `ScrollSpy()`, `transitionEnd()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Create`** (3 nodes): `generate_hosts_ini()`, `Generate hosts.ini content from services dict`, `create_local_inventory.py`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Hadoop`** (2 nodes): `Hadoop Molecule Test (test_default.py)`, `test_hosts_file Function (test_default.py)`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Ala`** (1 nodes): `ALA Install Ansible README (Groovy skeleton scripts)`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Demo`** (1 nodes): `Demo Navigation Bar (Species, Lists, Collections, Occurrences)`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Darwin Core Vocabulary` connect `Dwc` to `Vocab`, `Config`?**
  _High betweenness centrality (0.043) - this node is a cross-community bridge._
- **Why does `BIE (Species Pages / Biodiversity Information Explorer)` connect `Ala` to `Config`?**
  _High betweenness centrality (0.034) - this node is a cross-community bridge._
- **Why does `BIE Solr Index (Species/Taxonomy Search Index)` connect `Config` to `Ala`?**
  _High betweenness centrality (0.034) - this node is a cross-community bridge._
- **What connects `Perform a `re.sub` on every item in the list`, `OAuth impl for GitHub`, `Returns the user using the GitHub User API.` to the rest of the system?**
  _98 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Ala` be split into smaller, more focused modules?**
  _Cohesion score 0.11 - nodes in this community are weakly interconnected._
- **Should `Ansible` be split into smaller, more focused modules?**
  _Cohesion score 0.1 - nodes in this community are weakly interconnected._
- **Should `Ala` be split into smaller, more focused modules?**
  _Cohesion score 0.14 - nodes in this community are weakly interconnected._