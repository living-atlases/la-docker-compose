# inventories/testing/

Test inventories for local docker-compose deployment. Copied from a `yo living-atlas`-generated
lademo inventory with sensitive values removed.

## Origin

Files here are copies of:
- `/data/la-toolkit/config/lademo/lademo-inventories/lademo-dev-docker-inventory.ini`
- `/data/la-toolkit/config/lademo/lademo-inventories/lademo-local-extras.ini`

The generator (`yo living-atlas`) is the source of truth. Re-copy from there when the generator
updates inventory structure.

## Secrets stripped

The following vars are cleared (left empty) so the generator autogenerates new values on first run:

- `pac4j_cookie_signing_key`
- `pac4j_cookie_encryption_key`
- `cas_webflow_signing_key`
- `cas_webflow_encryption_key`
- `doi_datacite_password`

## Usage

```bash
cd /path/to/lademo-inventories

./ansiblew \
  --alainstall=../ala-install \
  --ladocker=../la-docker-compose \
  --docker-local \
  --nodryrun all
```

`--docker-local` makes ansiblew use `lademo-dev-docker-inventory.ini` (all hosts on 127.0.0.1)
instead of `lademo-inventory.ini` (remote hosts).

`--ladocker` makes ansiblew run `la-docker-compose` playbooks instead of ala-install playbooks
for docker container hosts.
