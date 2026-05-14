## Living Atlas Demo: Ansible Inventories

These are some generated inventories to use to set up some servers on EC2 or other cloud provider with LA software.

### Urls of your LA node

- Main landing page: https://l-a.site
- Collections: https://collections.l-a.site
- Collections administration: https://collections.l-a.site/admin
- Collections alaAdmin: https://collections.l-a.site/alaAdmin
- Biocache (occurrences): https://records.l-a.site
- Biocache administration: https://records.l-a.site/admin
- Biocache webservice: https://records-ws.l-a.site
- Species: https://species.l-a.site
- Species webservice: https://species-ws.l-a.site
- Species webservice administration: https://species-ws.l-a.site/admin
- SOLR non-public web interface: http://solr.l-a.site:8983 (You should use ssh port redirection to access this)
- CAS Auth system: https://auth.l-a.site/cas
- User details: https://auth.l-a.site/userdetails
- User details administration: https://auth.l-a.site/userdetails/admin
- User details alaAdmin https://auth.l-a.site/userdetails/alaAdmin
- Apikey management: https://auth.l-a.site/apikey/
- CAS management administration: https://auth.l-a.site/cas-management/
- Logger: https://logger.l-a.site/
- Logger administration: https://logger.l-a.site/admin
- Images service: https://images.l-a.site/
- Images service administration: https://images.l-a.site/admin
- Species list: https://lists.l-a.site
- Species list administration: https://lists.l-a.site/admin
- Regions: https://regions.l-a.site
- Regions administration: https://regions.l-a.site/alaAdmin
- Spatial: https://spatial.l-a.site
- Spatial Webservice: https://spatial.l-a.site/ws
- Spatial Geoserver: https://spatial.l-a.site/geoserver/
- Alerts service: https://alerts.l-a.site/
- Alerts service administration: https://alerts.l-a.site/admin
- DOI service: https://doi.l-a.site/
- DOI service administration: https://doi.l-a.site/admin

### Initial Setup

To use this, add the following into your `/etc/hosts` (of your working server, and new service server/s) and/or in your l-a.site `DNS`. So these hostname should be accessible from your local working server but also remotely between each server/s so the hostname should resolve correctly.

```
12.12.12.12  localhost
12.12.12.13  
```

You'll need to replace `12.12.12.1` etc with the IP address of some new Ubuntu instances in your provider.

These servers should have an user `ubuntu` with `sudo` permissions.

You should generate and use some ssh key and copy `~/.ssh/MyKey.pub` in those servers under `~ubuntu/.ssh/authorized_keys` (via `ssh-copy-id` for avoid issues). See the `dot-ssh-config` as sample.

You can test your initial setup with some `ssh` command like:
```
ssh -i ~/.ssh/MyKey.pem ubuntu@12.12.12.1 sudo ls /root
```
that should work.

### Run ansible

With access to this server/s you can run ansible with commands like:

```
export AI=<location-of-your-cloned-ala-install-repo>

#  For this demo to run well, we recommend a server of 16GB RAM, 4 CPUs.

ansible-playbook --private-key ~/.ssh/MyKey.pem -u ubuntu -i lademo-inventory.ini -i lademo-local-extras.ini -i lademo-local-passwords.ini $AI/ansible/branding.yml --limit l-a.site

ansible-playbook --private-key ~/.ssh/MyKey.pem -u ubuntu -i lademo-inventory.ini -i lademo-local-extras.ini -i lademo-local-passwords.ini $AI/ansible/collectory-by-type.yml --limit localhost
ansible-playbook --private-key ~/.ssh/MyKey.pem -u ubuntu -i lademo-inventory.ini -i lademo-local-extras.ini -i lademo-local-passwords.ini $AI/ansible/biocache-hub-by-type.yml --limit localhost
ansible-playbook --private-key ~/.ssh/MyKey.pem -u ubuntu -i lademo-inventory.ini -i lademo-local-extras.ini -i lademo-local-passwords.ini $AI/ansible/biocache-service-by-type.yml --limit localhost
ansible-playbook --private-key ~/.ssh/MyKey.pem -u ubuntu -i lademo-inventory.ini -i lademo-local-extras.ini -i lademo-local-passwords.ini $AI/ansible/bie-hub-by-type.yml --limit localhost
ansible-playbook --private-key ~/.ssh/MyKey.pem -u ubuntu -i lademo-inventory.ini -i lademo-local-extras.ini -i lademo-local-passwords.ini $AI/ansible/bie-index-by-type.yml --limit localhost
ansible-playbook --private-key ~/.ssh/MyKey.pem -u ubuntu -i lademo-inventory.ini -i lademo-local-extras.ini -i lademo-local-passwords.ini $AI/ansible/image-service-by-type.yml --limit localhost
ansible-playbook --private-key ~/.ssh/MyKey.pem -u ubuntu -i lademo-inventory.ini -i lademo-local-extras.ini -i lademo-local-passwords.ini $AI/ansible/species-list-by-type.yml --limit localhost
ansible-playbook --private-key ~/.ssh/MyKey.pem -u ubuntu -i lademo-inventory.ini -i lademo-local-extras.ini -i lademo-local-passwords.ini $AI/ansible/regions-by-type.yml --limit localhost
ansible-playbook --private-key ~/.ssh/MyKey.pem -u ubuntu -i lademo-inventory.ini -i lademo-local-extras.ini -i lademo-local-passwords.ini $AI/ansible/logger-service-by-type.yml --limit localhost
ansible-playbook --private-key ~/.ssh/MyKey.pem -u ubuntu -i lademo-inventory.ini -i lademo-local-extras.ini -i lademo-local-passwords.ini $AI/ansible/solrcloud-by-type.yml --limit localhost
ansible-playbook --private-key ~/.ssh/MyKey.pem -u ubuntu -i lademo-inventory.ini -i lademo-local-extras.ini -i lademo-local-passwords.ini $AI/ansible/auth-by-type.yml --limit localhost
ansible-playbook --private-key ~/.ssh/MyKey.pem -u ubuntu -i lademo-inventory.ini -i lademo-local-extras.ini -i lademo-local-passwords.ini $AI/ansible/spatial-by-type.yml --limit localhost
ansible-playbook --private-key ~/.ssh/MyKey.pem -u ubuntu -i lademo-inventory.ini -i lademo-local-extras.ini -i lademo-local-passwords.ini $AI/ansible/alerts-standalone.yml --limit localhost
ansible-playbook --private-key ~/.ssh/MyKey.pem -u ubuntu -i lademo-inventory.ini -i lademo-local-extras.ini -i lademo-local-passwords.ini $AI/ansible/doi-service-standalone.yml --limit localhost
ansible-playbook --private-key ~/.ssh/MyKey.pem -u ubuntu -i lademo-inventory.ini -i lademo-local-extras.ini -i lademo-local-passwords.ini $AI/ansible/sds.yml --limit localhost
ansible-playbook --private-key ~/.ssh/MyKey.pem -u ubuntu -i lademo-inventory.ini -i lademo-local-extras.ini -i lademo-local-passwords.ini $AI/ansible/pipelines.yml --limit localhost
ansible-playbook --private-key ~/.ssh/MyKey.pem -u ubuntu -i lademo-inventory.ini -i lademo-local-extras.ini -i lademo-local-passwords.ini $AI/ansible/data_quality_filter_service.yml --limit localhost
ansible-playbook --private-key ~/.ssh/MyKey.pem -u ubuntu -i lademo-inventory.ini -i lademo-local-extras.ini -i lademo-local-passwords.ini $AI/ansible/namematching-service-by-type.yml --limit localhost
ansible-playbook --private-key ~/.ssh/MyKey.pem -u ubuntu -i lademo-inventory.ini -i lademo-local-extras.ini -i lademo-local-passwords.ini $AI/ansible/sensitive-data-service-by-type.yml --limit localhost
ansible-playbook --private-key ~/.ssh/MyKey.pem -u ubuntu -i lademo-inventory.ini -i lademo-local-extras.ini -i lademo-local-passwords.ini $AI/ansible/branding.yml --limit localhost
ansible-playbook --private-key ~/.ssh/MyKey.pem -u ubuntu -i lademo-inventory.ini -i lademo-local-extras.ini -i lademo-local-passwords.ini $AI/ansible/docker-compose.yml --limit localhost
ansible-playbook --private-key ~/.ssh/MyKey.pem -u ubuntu -i lademo-inventory.ini -i lademo-local-extras.ini -i lademo-local-passwords.ini $AI/ansible/gatus.yml --limit localhost
ansible-playbook --private-key ~/.ssh/MyKey.pem -u ubuntu -i lademo-inventory.ini -i lademo-local-extras.ini -i lademo-local-passwords.ini $AI/ansible/portainer.yml --limit localhost
ansible-playbook --private-key ~/.ssh/MyKey.pem -u ubuntu -i lademo-inventory.ini -i lademo-local-extras.ini -i lademo-local-passwords.ini $AI/ansible/cassandra-docker.yml --limit localhost
```
#### ansible-playbook wrapper

Also there is the utility `ansiblew` an `ansible-playbook` wrapper that can help you to exec these commands and can be easily modificable by you to your needs. It depends on `python-docopt` package. Help output:

```
$ ./ansiblew --help

This is an ansible wrapper to help you to exec the different playbooks with your
inventories.

By default don't exec nothing only show the commands. With --nodryrun you can exec
the real commands.

With 'main' only operates over your main host.

Usage:
   ansiblew --alainstall=<dir_of_ala_install_repo> [options] [ main | collectory | ala_hub | biocache_service | ala_bie | bie_index | images | lists | regions | logger | solr | cas | biocache_backend | biocache_cli | spatial |  all ]
   ansiblew -h | --help
   ansiblew -v | --version

Options:
  --nodryrun             Exec the ansible-playbook commands
  -p --properties        Only update properties
  -l --limit=<hosts>     Limit to some inventories hosts
  -s --skip=<tags>       Skip tags
  -h --help              Show help options.
  -d --debug             Show debug info.
  -v --version           Show ansiblew version.
----
ansiblew 0.1.0
Copyright (C) 2019 living-atlases.gbif.org
Apache 2.0 License
```
So you can install the CAS service or the spatial service with commands like:

```bash
./ansiblew --alainstall=../ala-install cas --nodryrun
```

and

```bash
./ansiblew --alainstall=../ala-install spatial --nodryrun
```

or all the services with something like:

```bash
./ansiblew --alainstall=../ala-install all --nodryrun
```

### Rerunning the generator

You can rerun the generator with the option `yo living-atlas --replay` to use all the previous responses and regenerate the inventories with some modification (if for instance you want to add a new service, or using a new version of this generator with improvements).

You can also use `yo living-atlas --replay-dont-ask` if you only want to repeat the inventories generation (for instance, with a new version of the living-atlas generator to get some update, or when you edit carefully the `../.yo-rc.json` answers file to, for instance, enable ssl or some service, and only want to regenerate the inventories with the changes).

Also, you can use `--debug` to see some verbose debug info.

We recommend to override and set variables adding then to `lademo-local-extras.ini` without modify the generated `lademo-inventory.ini`, so you can rerun the generator in the future without lost local changes. The `*-local-extras.sample` files will be updated with future versions of this generator, so you can compare from time to time these samples with your `*-local-extras.ini` files to add new vars, etc.
