// CI safety net: the destructive stages (Clean machines, Pre-Deploy Docker
// Cleanup) wipe /data and /var/lib/docker. They must only ever touch known
// DISPOSABLE test hosts — if someone points TARGET_HOSTS at a production
// machine with CLEAN_MACHINE left at its default (true), abort before any ssh.
// Production deploys additionally set la_env=production in their inventory,
// which makes the Ansible side refuse destructive flags (enforce-production-safety.yml).
def assertDisposableHosts(String hostsStr, String allowRegex) {
    hostsStr.trim().split(/\s+/).each { h ->
        if (!(h ==~ allowRegex)) {
            error("SAFETY: host '${h}' does not match CLEAN_HOSTS_ALLOW_REGEX (${allowRegex}) — " +
                  "refusing to run a destructive cleanup stage. Is TARGET_HOSTS pointing at production?")
        }
    }
}

pipeline {
    agent any

    tools {
        nodejs 'node-22'
    }

    options {
        disableConcurrentBuilds()
        timestamps()
        ansiColor('xterm')
    }

    environment {
        // Effective TARGET_HOSTS is resolved in the 'Resolve topology' stage
        // (declarative environment{} vars cannot be reassigned from script, so the
        // default lives under a different name). A job-level TARGET_HOSTS env
        // override still wins.
        DEFAULT_TARGET_HOSTS = "gbif-es-docker-cluster-2023-1 gbif-es-docker-cluster-2023-2 gbif-es-docker-cluster-2023-3"

        BASE_DIR = "${env.HOME}/ala-install-docker-tests"
        GENERATOR_DIR = "${BASE_DIR}/generator-living-atlas"
        
        INVENTORY_PARENT_DIR = "${BASE_DIR}/lademo"
        INVENTORY_DIR = "${INVENTORY_PARENT_DIR}/lademo-inventories"

        VENV_DIR = "${BASE_DIR}/.venv-ansible"

        GENERATOR_GIT_URL = "https://github.com/living-atlases/generator-living-atlas.git"

        // Hosts the destructive cleanup stages are allowed to touch (disposable CI machines).
        CLEAN_HOSTS_ALLOW_REGEX = 'gbif-es-docker-cluster-.*|la-mh-[0-9]+|docker-[0-9]+|localhost|127\\.0\\.0\\.1'
    }

    parameters {
        booleanParam(
            name: 'FORCE_REDEPLOY',
            defaultValue: true,
            description: 'Run inventories + redeploy even if no changes are detected'
        )
        booleanParam(
            name: 'CLEAN_MACHINE',
            defaultValue: true,
            description: 'Wipe /data (except lost+found) and purge Docker before running'
        )
        booleanParam(
            name: 'ONLY_CLEAN',
            defaultValue: false,
            description: 'Only clean machines and stop'
        )
        choice(
            name: 'TOPOLOGY',
            choices: ['default', '3host-alt', '2host', '1host'],
            description: 'Deployment topology. default = the la-toolkit-synced layout (current 3-host split, untouched). Any other value applies topologies/<name>.placement.json over the agent\'s .yo-rc (backed up and restored on the next default build), trims TARGET_HOSTS to the variant\'s host count and merges its skip_services. MANUAL BUILDS ONLY — SCM-triggered builds refuse non-default topologies. Remember to point the external front proxy per topologies/README.md (scripts/apply-topology.py proxy-map) before/after.'
        )
        string(
            name: 'GENERATOR_BRANCH',
            defaultValue: 'master',
            description: 'Branch of generator-living-atlas to use'
        )
        booleanParam(
            name: 'AUTO_DEPLOY',
            defaultValue: true,
            description: 'Automatically start containers after generating configuration'
        )
        string(
            name: 'SKIP_SERVICES',
            // Deferred (out of scope for now): sds-static-home, sensitive-data-service.
            //  - doi-service: STILL STARTING/INITIALIZING (CI #234/#235). Root cause known: it is a
            //    GRAILS app using the grails-elasticsearch plugin, which on boot
            //    (SearchableClassMappingConfigurator.installMappings -> ElasticSearchAdminService
            //    .indexExists) connects to ES and, with no elasticSearch.client.hosts config,
            //    defaults to localhost:9200 -> Connection refused -> never healthy. (SPRING_
            //    ELASTICSEARCH_URIS does NOT help — that is Spring Boot config, not Grails.) Fix is
            //    to set the grails-elasticsearch host (-> elasticsearch:9200) in doi-service-config
            //    .yml; deferred until validated locally to avoid burning 47-min CI cycles.
            // Re-enabled (tanda 1, CI #232 green): spatial, spatial-service, geoserver — healthy;
            // geoserver has the ALA workspace + LayersDB datastore (functional init). Fixes: ship
            // spatial-logback.xml + -Dlogging.config (Logback rejected the role's log4j.properties),
            // spatial-service security.cas.appServerName (CAS filter init), layersdb uuid-ossp.
            // Re-enabled (tanda 2, CI #233 green): geonetwork — postgres md5 (password_encryption=md5
            // + pg_hba rewrite) for the image's old libpq that can't do SCRAM; healthy end-to-end.
            // Removing any token re-enables that service. Goal: keep CI green while these are fixed.
            defaultValue: 'sds-static-home,sensitive-data-service,doi-service',
            description: 'Comma-separated inventory groups to skip (temporary: immature/crash-looping services). Empty to deploy everything.'
        )
        booleanParam(
            name: 'RUN_E2E',
            defaultValue: true,
            description: 'Run post-deploy verification (Gatus health gate + Cypress smoke). Report-only.'
        )
        booleanParam(
            name: 'E2E_BLOCKING',
            defaultValue: false,
            description: 'If true, a verification failure fails the build. If false, it only marks the stage UNSTABLE.'
        )
        booleanParam(
            name: 'ENABLE_AUTH_TESTS',
            defaultValue: true,
            description: 'Include the CAS/OIDC login smoke test. Logs in as the CAS admin, with credentials read from the inventory local-passwords.ini (email var + the plaintext password left in a comment).'
        )
        booleanParam(
            name: 'TEST_REDEPLOY',
            defaultValue: false,
            description: 'Hot-redeploy integrity test: after the green deploy, seed canary data (file + MySQL row), snapshot container IDs, start an nginx availability probe, re-run the playbooks WITHOUT cleaning, and assert nothing was destroyed, no downtime, and unchanged services kept their containers. Adds one full playbook run to the build.'
        )
        booleanParam(
            name: 'RUN_AIRFLOW_INGEST',
            defaultValue: true,
            description: 'Run the Airflow ingestion e2e: ingest a tiny fixed DwCA through the real pipeline and assert records in Solr + biocache. Runs against the ALREADY-RUNNING stack (independent of redeploy) — set this true with FORCE_REDEPLOY=false to test ingestion without a full deploy. Report-only unless E2E_BLOCKING. The ingested data also seeds the Cypress biocache/species suites.'
        )
    }

    stages {
        // Resolve TOPOLOGY before anything destructive: trims TARGET_HOSTS to the
        // variant's host count (unused VMs are never cleaned nor deployed to) and
        // exposes the variant's skip_services for the deploy stages. Non-default
        // topologies are gated to MANUAL builds so a plain push can never redeploy
        // the cluster with an alternative layout.
        stage('Resolve topology') {
            steps {
                script {
                    def topo = params.TOPOLOGY ?: 'default'
                    env.TOPOLOGY_SKIP_SERVICES = ''
                    if (!env.TARGET_HOSTS?.trim()) {
                        env.TARGET_HOSTS = env.DEFAULT_TARGET_HOSTS
                    }
                    if (topo != 'default') {
                        if (currentBuild.getBuildCauses('hudson.triggers.SCMTrigger$SCMTriggerCause')) {
                            error("SAFETY: TOPOLOGY=${topo} is only allowed on manually triggered builds — an SCM-triggered build must deploy the default topology.")
                        }
                        def placementFile = "topologies/${topo}.placement.json"
                        if (!fileExists(placementFile)) {
                            error("TOPOLOGY=${topo}: ${placementFile} not found")
                        }
                        def allHosts = env.TARGET_HOSTS.trim().split(/\s+/)
                        def hostCount = sh(returnStdout: true,
                            script: "python3 -c \"import json; print(len(json.load(open('${placementFile}'))['hosts']))\"").trim().toInteger()
                        if (hostCount > allHosts.size()) {
                            error("TOPOLOGY=${topo} needs ${hostCount} hosts but TARGET_HOSTS only has ${allHosts.size()}")
                        }
                        // Sandbox-safe host slice (Groovy's Object[].take() is not
                        // whitelisted in the Jenkins script sandbox): index-loop instead.
                        def picked = []
                        for (int i = 0; i < hostCount; i++) { picked.add(allHosts[i]) }
                        env.TARGET_HOSTS = picked.join(' ')
                        env.TOPOLOGY_SKIP_SERVICES = sh(returnStdout: true,
                            script: "python3 -c \"import json; print(','.join(json.load(open('${placementFile}')).get('skip_services', [])))\"").trim()
                        currentBuild.description = "TOPOLOGY=${topo} (${hostCount} hosts)"
                        echo "TOPOLOGY=${topo}: TARGET_HOSTS=${env.TARGET_HOSTS} topology skip_services=${env.TOPOLOGY_SKIP_SERVICES}"
                        echo "REMINDER: the external front proxy must route the public vhosts per this variant (scripts/apply-topology.py proxy-map — see topologies/README.md)."
                    }
                }
            }
        }

        stage('Clean machines') {
            // Never wipe in ingest-only mode (RUN_AIRFLOW_INGEST without FORCE_REDEPLOY), even if
            // CLEAN_MACHINE is left at its default true — the intent there is to test the ingest
            // against the live stack, not to destroy it.
            when { expression { (params.CLEAN_MACHINE || params.ONLY_CLEAN) && !(params.RUN_AIRFLOW_INGEST && !params.FORCE_REDEPLOY) } }
            steps {
                script {
                    assertDisposableHosts(env.TARGET_HOSTS, env.CLEAN_HOSTS_ALLOW_REGEX)
                    def hosts = env.TARGET_HOSTS.trim().split(/\s+/)
                    
                    // Pre-scan SSH keys for remote hosts
                    for (h in hosts) {
                        if (h != 'localhost' && h != '127.0.0.1') {
                            sh("""
                                set +e
                                ssh-keygen -f "\$HOME/.ssh/known_hosts" -R "${h}" >/dev/null 2>&1
                                ip=\$(ssh -G "${h}" | awk '/^hostname /{print \$2; exit}')
                                if [ -n "\$ip" ]; then
                                    ssh-keygen -f "\$HOME/.ssh/known_hosts" -R "\$ip" >/dev/null 2>&1
                                    ssh-keyscan -H "\$ip" >> "\$HOME/.ssh/known_hosts" 2>/dev/null
                                fi
                                ssh-keyscan -H "${h}" >> "\$HOME/.ssh/known_hosts" 2>/dev/null
                                set -e
                            """.stripIndent())
                        }
                    }

                    def jobs = [:]
                    for (h in hosts) {
                        def targetHost = h
                        jobs[targetHost] = {
                            sh("""
                                set -eu
                                def_clean_script=\$(cat <<'EOF'
                                set -eu
                                echo "==> Cleaning on \$(hostname)"
                                
                                # 1. Stop and clean Docker state (keep images for speed)
                                if command -v docker >/dev/null 2>&1; then
                                    echo "Cleaning Docker state (preserving images for cache)..."
                                    
                                    # Stop all running containers
                                    if [ -d /data/docker-compose ]; then
                                        echo "  - Stopping compose containers..."
                                        sudo find /data/docker-compose -maxdepth 2 -name "docker-compose.yml" -execdir docker compose down -v \\; || true
                                    fi
                                    
                                    # Remove phantom containers in terminal states (prevents accumulation)
                                    echo "  - Removing exited and created containers..."
                                    sudo docker ps -aq -f 'status=exited' | xargs -r sudo docker rm -f 2>/dev/null || true
                                    sudo docker ps -aq -f 'status=created' | xargs -r sudo docker rm -f 2>/dev/null || true

                                    # CLEAN_MACHINE must truly wipe the datastores: `docker compose down -v`
                                    # does NOT remove external:true volumes, so la_mysql-data / la_mongodb-data /
                                    # la_ala-i18n-data persisted across "clean" deploys (emmet stayed 0900 since
                                    # 2026-02, masking schema/init changes). Force-remove them here. Scoped to
                                    # these small auth/i18n datastores by name; solr/cassandra volumes (other
                                    # names / hosts) are intentionally NOT wiped to avoid expensive re-index.
                                    echo "  - Force-removing external datastore volumes (mysql/mongo/i18n)..."
                                    sudo docker rm -f la_mysql la_mongodb la_ala-i18n 2>/dev/null || true
                                    sudo docker volume rm -f la_mysql-data la_mongodb-data la_ala-i18n-data 2>/dev/null || true

                                    # Clean BuildKit cache and dangling resources
                                    echo "  - Pruning BuildKit cache..."
                                    sudo docker builder prune -af 2>/dev/null || true
                                    
                                    echo "  - Pruning dangling images, volumes, and networks..."
                                    sudo docker system prune -f --volumes 2>/dev/null || true
                                    
                                    # Restart Docker to ensure clean state
                                    echo "  - Restarting Docker daemon..."
                                    sudo systemctl restart docker containerd 2>/dev/null || true
                                    sleep 2
                                fi

                                # 2. Kill unattended-upgrades (safe: CI nodes are being wiped anyway)
                                echo "  - Stopping unattended-upgrades if running..."
                                sudo systemctl stop unattended-upgrades 2>/dev/null || true
                                sudo pkill -9 -x unattended-upgrades 2>/dev/null || true
                                # Wait for dpkg lock-frontend to be released (max 2 min)
                                # flock rc=0 means lock acquired (free), rc=1 means locked
                                i=0
                                while ! sudo flock --nonblock /var/lib/dpkg/lock-frontend true 2>/dev/null; do
                                    i=\$((i+1))
                                    echo "  - dpkg lock held, waiting... (\${i}/24)"
                                    if [ "\$i" -ge 24 ]; then echo "ERROR: dpkg lock busy for too long"; exit 1; fi
                                    sleep 5
                                done
                                echo "  - dpkg lock free, continuing"

                                # 3. Wipe /data (preserving lost+found and var-lib-containerd for volume caching)
                                if [ -d /data ]; then
                                    echo "Cleaning /data directory..."
                                    sudo find /data -mindepth 1 -maxdepth 1 -not -name lost+found -not -name var-lib-containerd -print -exec rm -rf -- {} + || true
                                fi

                                 # 4. Clean docker config but keep images and daemon settings for idempotence
                                 echo "Cleaning Docker config directories..."
                                 sudo rm -rf /etc/docker/certs.d /etc/docker/*.json /etc/systemd/system/docker.service.d || true
                                 sudo rm -f /var/run/docker.sock || true
                                 
                                 # 5. Recreate Docker socket for API connectivity
                                 echo "  - Recreating Docker socket..."
                                 sudo systemctl restart docker.socket 2>/dev/null || true
                                 sleep 1
                                 
                                 # Note: NOT removing /etc/docker/daemon.json or Docker packages
                                 # This preserves Docker installation for faster playbook runs
EOF
                                )

                                if [ "${targetHost}" = "localhost" ] || [ "${targetHost}" = "127.0.0.1" ]; then
                                    bash -c "\$def_clean_script"
                                else
                                    echo "\$def_clean_script" | ssh ${targetHost} bash -s
                                fi
                            """.stripIndent())
                        }
                    }
                    parallel jobs
                }
            }
        }

        stage('Unit tests') {
            when { expression { !params.ONLY_CLEAN } }
            steps {
                sh '''
                    set -eu
                    VENV_MOL="${WORKSPACE}/.venv-molecule"
                    if [ ! -d "$VENV_MOL" ]; then
                        python3 -m venv "$VENV_MOL"
                    fi
                    "$VENV_MOL/bin/pip" install --quiet --upgrade pip
                    "$VENV_MOL/bin/pip" install --quiet molecule ansible-core
                    VENV_MOLECULE="$VENV_MOL" PATH="$VENV_MOL/bin:$PATH" "$VENV_MOL/bin/molecule" test -s unit
                '''
            }
        }

        // Level-1 topology validation: every topologies/*.placement.json variant is
        // checked against its COMMITTED fixture inventory (resolved-hostvars only:
        // scope leaks, orphan services, duplicated vhosts, placement invariants).
        // No real hosts, no docker, no node — seconds per variant, runs on every build.
        stage('Topology matrix') {
            when { expression { !params.ONLY_CLEAN } }
            steps {
                sh '''
                    set -eu
                    VENV_MOLECULE="${WORKSPACE}/.venv-molecule" bash scripts/test-topologies.sh
                '''
            }
        }

        stage('Prepare environment') {
            when { expression { !params.ONLY_CLEAN } }
            steps {
                sh """
                    set -eu
                    
                    echo "Creating base directories..."
                    mkdir -p "${BASE_DIR}" "${GENERATOR_DIR}" "${INVENTORY_PARENT_DIR}" "${INVENTORY_DIR}"
                    
                    echo "Initializing ala-install submodule..."
                    git submodule update --init --remote ala-install
                    echo "ala-install submodule SHA: \$(git -C ala-install rev-parse HEAD)"
                    # Disable sparse checkout in case it was left active from a prior build
                    git -C ala-install config core.sparseCheckout false 2>/dev/null || true
                    git -C ala-install read-tree -mu HEAD 2>/dev/null || true
                    echo "ala-install SQL files present: \$(ls ala-install/ansible/roles/logger-service/files/db/*.sql 2>/dev/null | wc -l || echo 0)"

                    # pipelines-airflow submodule: pinned SHA (NO --remote) — only needed
                    # when use_airflow=true (NO-AWS overlay). Soft-fail so it never blocks
                    # the stack build when Airflow is disabled.
                    echo "Initializing pipelines-airflow submodule (pinned SHA)..."
                    git submodule update --init pipelines-airflow || true
                    echo "pipelines-airflow submodule SHA: \$(git -C pipelines-airflow rev-parse HEAD 2>/dev/null || echo MISSING)"

                    echo "Setting up Python virtual environment for Ansible..."
                    if [ ! -d "${VENV_DIR}" ]; then
                        python3 -m venv "${VENV_DIR}"
                    fi
                    
                    # Upgrade pip
                    "${VENV_DIR}/bin/pip" install --upgrade pip
                    
                    # Install Ansible
                    "${VENV_DIR}/bin/pip" install ansible
                    
                    # Verify Ansible installation
                    echo "Verifying Ansible installation..."
                    test -x "${VENV_DIR}/bin/ansible-playbook" || { echo "ERROR: ansible-playbook not found in venv"; exit 1; }
                    "${VENV_DIR}/bin/ansible-playbook" --version
                    
                    echo "Ansible venv ready at: ${VENV_DIR}"
                """
            }
        }

        stage('Update dependencies') {
            when { expression { !params.ONLY_CLEAN } }
            steps {
                sh """
                    set -eu
                    if [ ! -d "${GENERATOR_DIR}/.git" ]; then
                        rm -rf "${GENERATOR_DIR}"
                        git clone "${env.GENERATOR_GIT_URL}" "${GENERATOR_DIR}"
                    else
                        # Aggressively clean node_modules BEFORE git operations
                        if [ -d "${GENERATOR_DIR}/node_modules" ]; then
                            echo "Pre-cleaning node_modules in generator-living-atlas..."
                            chmod -R u+w "${GENERATOR_DIR}/node_modules" 2>/dev/null || true
                            rm -rf "${GENERATOR_DIR}/node_modules"
                        fi
                    fi
                    cd "${GENERATOR_DIR}"
                    git fetch --prune origin
                    git checkout -B "${params.GENERATOR_BRANCH}" "origin/${params.GENERATOR_BRANCH}"
                    git reset --hard "origin/${params.GENERATOR_BRANCH}"
                    git clean -fdx
                """
            }
        }

        stage('Decide redeploy') {
            when { expression { !params.ONLY_CLEAN } }
            steps {
                script {
                    def isManual = currentBuild.rawBuild.getCause(hudson.model.Cause$UserIdCause) != null
                    def isCron = currentBuild.rawBuild.getCause(hudson.triggers.TimerTrigger$TimerTriggerCause) != null

                    // Ingest-only run: RUN_AIRFLOW_INGEST without FORCE_REDEPLOY means "test the
                    // ingest against the ALREADY-RUNNING stack" — never redeploy. This MUST win over
                    // the isManual heuristic below: a build triggered via the API/MCP authenticates
                    // as a user (UserIdCause) so isManual=true, which would otherwise flip
                    // DO_REDEPLOY=true and run the destructive Pre-Deploy Docker Cleanup (nuclear
                    // /var/lib/docker wipe) before the ingest ever runs. Guard it explicitly.
                    if (params.RUN_AIRFLOW_INGEST && !params.FORCE_REDEPLOY) {
                        env.DO_REDEPLOY = 'false'
                        echo 'Ingest-only run (RUN_AIRFLOW_INGEST, no FORCE_REDEPLOY): skipping redeploy + docker cleanup.'
                    } else if (params.FORCE_REDEPLOY || (isManual && !isCron)) {
                        env.DO_REDEPLOY = 'true'
                        echo 'Force or Manual redeploy detected.'
                    } else {
                        def results = sh(
                            script: """
                                set -eu
                                GEN_SHA=\$(cd "${GENERATOR_DIR}" && git rev-parse HEAD)
                                SELF_SHA=\$(git rev-parse HEAD)
                                
                                GEN_FILE="${BASE_DIR}/.last_sha_gen"
                                SELF_FILE="${BASE_DIR}/.last_sha_self"
                                
                                CHANGED="false"
                                if [ ! -f "\$GEN_FILE" ] || [ "\$(cat "\$GEN_FILE")" != "\$GEN_SHA" ]; then echo "\$GEN_SHA" > "\$GEN_FILE"; CHANGED="true"; fi
                                if [ ! -f "\$SELF_FILE" ] || [ "\$(cat "\$SELF_FILE")" != "\$SELF_SHA" ]; then echo "\$SELF_SHA" > "\$SELF_FILE"; CHANGED="true"; fi
                                
                                echo "\$CHANGED|\$GEN_SHA|\$SELF_SHA"
                            """,
                            returnStdout: true
                        ).trim().split('\\|')

                        env.DO_REDEPLOY = (results[0] == 'true') ? 'true' : 'false'
                        echo "GEN_SHA:  ${results[1]}"
                        echo "SELF_SHA: ${results[2]}"
                    }
                    echo "Redeploy needed: ${env.DO_REDEPLOY}"
                }
            }
        }

        stage('Install generator deps') {
            when { expression { env.DO_REDEPLOY == 'true' && !params.ONLY_CLEAN } }
            steps {
                sh """
                    set -eu
                    
                    # Detect Node.js installation path (like reference Jenkinsfile)
                    NODE_HOME="\$(cd "\$(dirname "\$(which node)")/.." && pwd)"
                    NPM="node \$NODE_HOME/lib/node_modules/npm/bin/npm-cli.js"
                    
                    echo "Node version:"
                    node -v
                    echo "NPM version:"
                    \$NPM -v
                    
                    cd "${GENERATOR_DIR}"
                    
                    # Use npm ci if package-lock.json exists, otherwise npm install with --ignore-scripts
                    # The --ignore-scripts prevents husky from running post-install hooks which can fail
                    # if the old husky version is incompatible with newer Node versions
                    if [ -f package-lock.json ]; then
                        echo "Found package-lock.json, using npm ci for reproducibility..."
                        \$NPM ci --no-audit --no-fund --ignore-scripts
                    else
                        echo "No package-lock.json found, using npm install..."
                        \$NPM install --no-audit --no-fund --ignore-scripts
                    fi
                    
                    # Verify yeoman-generator is available (should be in package.json as devDependency)
                    test -d node_modules/yeoman-generator || { echo "ERROR: yeoman-generator not installed"; exit 1; }
                    echo "✓ yeoman-generator installed successfully"
                    
                    echo "Generator package version:"
                    node -e "console.log(require('./package.json').version)"
                """
            }
        }

        stage('Regenerate inventories') {
            when { expression { env.DO_REDEPLOY == 'true' && !params.ONLY_CLEAN } }
            steps {
                sh """
                    set -eu
                    
                    # Detect Node.js installation path
                    NODE_HOME="\$(cd "\$(dirname "\$(which node)")/.." && pwd)"
                    NPM="node \$NODE_HOME/lib/node_modules/npm/bin/npm-cli.js"
                    
                    cd "${INVENTORY_PARENT_DIR}"
                    
                    echo "Initializing npm environment in inventory directory..."
                    if [ ! -f package.json ]; then
                        \$NPM init -y >/dev/null 2>&1
                    fi
                    
                    # Clean up node_modules to ensure fresh installation
                    echo "Cleaning node_modules and package-lock.json..."
                    rm -rf node_modules package-lock.json
                    
                    echo "Installing generator and runner via npm..."
                    \$NPM install --no-audit --no-fund yo yeoman-environment yeoman-generator generator-living-atlas@latest
                    
                    # Verify installations
                    echo "Verifying installations..."
                    \$NPM ls yo --depth=0
                    \$NPM ls generator-living-atlas --depth=0
                    \$NPM ls yeoman-generator --depth=0
                    
                    echo "Generator version:"
                    node -e "console.log('generator-living-atlas:', require('generator-living-atlas/package.json').version)"
                    node -e "console.log('generator-living-atlas path:', require.resolve('generator-living-atlas/package.json'))"
                    
                    # Remove stale branding workspace so the republished (vite)
                    # generator writes a pristine tree. --force overwrites files
                    # the generator writes but never deletes ones it no longer
                    # writes, so a brunch→vite switch would otherwise leave a
                    # stale brunch-config.js / yarn.lock behind.
                    echo "Cleaning stale branding workspace before replay..."
                    rm -rf "${INVENTORY_PARENT_DIR}/lademo-branding"

                    # --- Topology overlay -------------------------------------------------
                    # The agent's .yo-rc.json is the la-toolkit-synced source of truth. For a
                    # non-default TOPOLOGY we back it up ONCE (.la-toolkit-base) and derive the
                    # variant .yo-rc from that pristine base, so repeated alternative builds
                    # never compound. The next default build restores the base and deletes the
                    # backup (NOTE: re-sync from la-toolkit only while no backup file exists,
                    # i.e. while the cluster is on the default topology).
                    YORC="${INVENTORY_PARENT_DIR}/.yo-rc.json"
                    YORC_BASE="${INVENTORY_PARENT_DIR}/.yo-rc.json.la-toolkit-base"
                    if [ "${params.TOPOLOGY}" != "default" ]; then
                        if [ ! -f "\$YORC_BASE" ]; then
                            cp "\$YORC" "\$YORC_BASE"
                            echo "Backed up la-toolkit .yo-rc to \$YORC_BASE"
                        fi
                        echo "Applying topology overlay: ${params.TOPOLOGY}"
                        python3 "${WORKSPACE}/scripts/apply-topology.py" apply \
                            --base "\$YORC_BASE" \
                            --placement "${WORKSPACE}/topologies/${params.TOPOLOGY}.placement.json" \
                            --out "\$YORC"
                        echo "Front-proxy routing this variant needs (apply in ansible-extras):"
                        python3 "${WORKSPACE}/scripts/apply-topology.py" proxy-map \
                            --base "\$YORC_BASE" \
                            --placement "${WORKSPACE}/topologies/${params.TOPOLOGY}.placement.json"
                    elif [ -f "\$YORC_BASE" ]; then
                        echo "TOPOLOGY=default: restoring la-toolkit .yo-rc from backup"
                        mv "\$YORC_BASE" "\$YORC"
                    fi
                    # ----------------------------------------------------------------------

                    echo "Running generator..."
                    node ./node_modules/yo/lib/cli.js living-atlas --replay-dont-ask --force
                    
                    echo "Verifying generated inventory..."
                    test -f "${INVENTORY_DIR}/lademo-inventory.ini" || { echo "ERROR: inventory not generated"; exit 1; }
                    ls -lh "${INVENTORY_DIR}/lademo-inventory.ini"
                    echo "✓ Inventory generated successfully"

                    # Refresh base-branding to its latest before it is packaged into the
                    # branding-builder image. The replay above provisions lademo-branding
                    # (a clone of living-atlases/base-branding); pull origin so CI builds
                    # with the CURRENT branding source (vite config, footer/head/banner).
                    #
                    # CRITICAL: the replay does NOT initialise base-branding's git submodules,
                    # so commonui-bs3-2019 is left as an EMPTY gitlink directory. That ALA
                    # submodule ships its build/ COMMITTED (js/css/fonts: bootstrap, jquery,
                    # ala-styles, application.js, font-awesome, autocomplete) at the pinned
                    # commit, and our pipeline only CONSUMES it (vite static-copy) — it never
                    # rebuilds commonui. An empty submodule => the bundle ships without those
                    # assets => apps requesting /brand-2023/css/ala-styles.css etc. get 404
                    # (ORB-blocked CSS/JS -> unstyled site). So we MUST check out the pinned
                    # submodule. Use --init (the recorded pin), NOT --remote (which would
                    # advance to a tip that may have dropped the committed build/).
                    # Non-blocking: a refresh hiccup must never fail the deploy, and it
                    # skips cleanly when the replayed tree is not a git checkout.
                    if [ -d "${INVENTORY_PARENT_DIR}/lademo-branding/.git" ]; then
                      # base-branding's canonical branch is `main` (github.com/living-atlases/base-branding).
                      # The replay's fresh clone checks out the repo DEFAULT branch — still `master`, which
                      # LACKS app/spatial/ (the Spatial Portal skin). On master the branding-builder ships
                      # without dist/spatial, so spatial-hub falls back to the stock ALA portal layout
                      # (skin.layout auto-detect finds no gsp -> portal). Force lademo-branding onto
                      # origin/main so CI builds the CURRENT branding (works even from a single-branch clone).
                      echo "Refreshing base-branding to origin/main..."
                      git -C "${INVENTORY_PARENT_DIR}/lademo-branding" fetch --prune origin main || echo "WARN: fetch origin/main failed (continuing with replayed tree)"
                      git -C "${INVENTORY_PARENT_DIR}/lademo-branding" checkout -B main FETCH_HEAD || echo "WARN: checkout main failed (continuing with replayed tree)"
                      echo "Initialising commonui-bs3-2019 submodule (ships committed build/ assets)..."
                      git -C "${INVENTORY_PARENT_DIR}/lademo-branding" submodule update --init commonui-bs3-2019 || echo "WARN: commonui submodule init failed (branding may miss commonui assets)"
                      if ls "${INVENTORY_PARENT_DIR}/lademo-branding/commonui-bs3-2019/build/css/ala-styles.css" >/dev/null 2>&1; then
                        echo "✓ commonui build/ present (ala-styles.css found)"
                      else
                        echo "WARN: commonui build/ missing after submodule init — branding bundle will lack commonui assets (ala-styles, jquery, bootstrap)"
                      fi
                    else
                      echo "INFO: ${INVENTORY_PARENT_DIR}/lademo-branding has no .git; skipping base-branding pull"
                    fi
                """
            }
        }

        stage('Pre-Deploy Docker Cleanup') {
            when { 
                expression { 
                    env.DO_REDEPLOY == 'true' && 
                    !params.ONLY_CLEAN && 
                    params.AUTO_DEPLOY
                }
            }
            steps {
                script {
                    assertDisposableHosts(env.TARGET_HOSTS, env.CLEAN_HOSTS_ALLOW_REGEX)
                    def hosts = env.TARGET_HOSTS.trim().split(/\s+/)
                    
                    def jobs = [:]
                    for (h in hosts) {
                        def targetHost = h
                        jobs[targetHost] = {
                            sh("""
                                set -eu
                                cleanup_script=\$(cat <<'EOF'
                                set -eu
                                echo "==> Pre-deploy Docker cleanup on \$(hostname)"
                                
                                 echo "==> NUCLEAR Docker cleanup (simulating clean machine)"
                                 
                                 if command -v docker >/dev/null 2>&1; then
                                     # 1. Stop Docker daemon AND socket to prevent auto-restart
                                     echo "  - Stopping Docker daemon and socket..."
                                     sudo systemctl stop docker.socket 2>/dev/null || true
                                     sudo systemctl stop docker
                                     sleep 2
                                     
                                     # 2. NUCLEAR: Remove ALL Docker state (simulates fresh install)
                                     # This removes containers, images, networks, build cache
                                     # BUT preserves external volumes at /data/ (mysql, solr, etc)
                                     echo "  - NUCLEAR: Removing /var/lib/docker/* (preserving external volumes in /data/)"
                                     sudo rm -rf /var/lib/docker/*
                                     echo "    ✓ Docker state completely removed"
                                     
                                     # 3. Start Docker fresh (will reinitialize from scratch)
                                     echo "  - Starting Docker daemon from clean state..."
                                     sudo systemctl start docker
                                     sleep 5
                                     
                                     # 4. Verify Docker is healthy with more retries (it takes longer after nuclear cleanup)
                                     echo "  - Verifying Docker is ready..."
                                     retry_count=0
                                     max_retries=40
                                     while [ \$retry_count -lt \$max_retries ]; do
                                         if sudo docker info >/dev/null 2>&1; then
                                             echo "    ✓ Docker is responding and healthy"
                                             break
                                         fi
                                         retry_count=\$((retry_count + 1))
                                         if [ \$retry_count -lt \$max_retries ]; then
                                             echo "    Retry \$retry_count/\$max_retries, waiting for Docker..."
                                             sleep 3
                                         fi
                                     done
                                     
                                     if [ \$retry_count -eq \$max_retries ]; then
                                         echo "ERROR: Docker not responding after nuclear cleanup (waited ~120s)"
                                         echo "  - one last restart attempt before giving up..."
                                         sudo systemctl restart docker 2>/dev/null || sudo systemctl start docker 2>/dev/null || true
                                         sleep 10
                                         if sudo docker info >/dev/null 2>&1; then
                                             echo "    ✓ Docker recovered after final restart"
                                         else
                                             echo "  - dumping docker daemon state for diagnosis:"
                                             sudo systemctl status docker --no-pager 2>&1 | tail -n 20 || true
                                             sudo journalctl -u docker --no-pager -n 40 2>&1 || true
                                             exit 1
                                         fi
                                     fi
                                     
                                     # 5. Confirm clean state
                                     echo "  - Confirming clean Docker state..."
                                     container_count=\$(sudo docker ps -a -q | wc -l)
                                     image_count=\$(sudo docker images -q | wc -l)
                                     echo "    Containers: \$container_count, Images: \$image_count (clean state)"
                                     
                                     echo "  ✓ NUCLEAR cleanup complete - Docker reinitialized from scratch"
                                 else
                                     echo "  ⚠ Docker not installed, skipping cleanup"
                                 fi
EOF
                                )
                                
                                if [ "${targetHost}" = "localhost" ] || [ "${targetHost}" = "127.0.0.1" ]; then
                                    bash -c "\$cleanup_script"
                                else
                                    echo "\$cleanup_script" | ssh ${targetHost} bash -s
                                fi
                            """.stripIndent())
                        }
                    }
                    parallel jobs
                }
            }
        }

        stage('Run Playbooks') {
            when { expression { env.DO_REDEPLOY == 'true' && !params.ONLY_CLEAN } }
            steps {
                script {
                    def playbook = params.AUTO_DEPLOY ? 'playbooks/site.yml' : 'playbooks/config-gen.yml'
                    
                    echo "Running playbook: ${playbook}"
                    echo "Auto-deploy: ${params.AUTO_DEPLOY}"
                    echo "Target hosts: ${env.TARGET_HOSTS}"
                    
                    // Build inventory arguments
                    def inventoryArg = "-i ${INVENTORY_DIR}/lademo-inventory.ini"
                    if (fileExists("${INVENTORY_DIR}/lademo-local-extras.ini")) {
                        inventoryArg += " -i ${INVENTORY_DIR}/lademo-local-extras.ini"
                        echo "Found lademo-local-extras.ini"
                    }
                    if (fileExists("${INVENTORY_DIR}/lademo-local-passwords.ini")) {
                        inventoryArg += " -i ${INVENTORY_DIR}/lademo-local-passwords.ini"
                        echo "Found lademo-local-passwords.ini"
                    }

                    // Temporary flag: skip immature services (e.g. SDS) without touching inventories.
                    // Merged with the active topology's skip_services (reduced variants trim
                    // heavy services they have no room for).
                    def skipArg = ''
                    def skipList = []
                    if (params.SKIP_SERVICES?.trim()) { skipList += params.SKIP_SERVICES.tokenize(',') }
                    if (env.TOPOLOGY_SKIP_SERVICES?.trim()) { skipList += env.TOPOLOGY_SKIP_SERVICES.tokenize(',') }
                    skipList = skipList.collect { it.trim() }.findAll { it }.unique()
                    if (skipList) {
                        skipArg = " --extra-vars '" + groovy.json.JsonOutput.toJson([skip_services: skipList]) + "'"
                        echo "Skipping services: ${skipList}"
                    }

                    sh """
                        set -eu

                        export PATH="${VENV_DIR}/bin:\$PATH"
                        export ANSIBLE_ROLES_PATH="${WORKSPACE}/ala-install/ansible/roles:${WORKSPACE}/roles"
                        export ANSIBLE_FORCE_COLOR=true
                        export ANSIBLE_STDOUT_CALLBACK=yaml
                        export ANSIBLE_HOST_KEY_CHECKING=False
                        
                        echo "Ansible version:"
                        ansible-playbook --version
                        
                        echo "Running playbook against docker_compose group (all hosts)..."
                        ansible-playbook ${playbook} ${inventoryArg} --limit docker_compose --extra-vars "auto_deploy=${params.AUTO_DEPLOY}"${skipArg} -v
                    """
                }
            }
        }

        stage('Validate Deployment') {
            when { expression { env.DO_REDEPLOY == 'true' && params.AUTO_DEPLOY && !params.ONLY_CLEAN } }
            steps {
                script {
                    def hosts = env.TARGET_HOSTS.trim().split(/\s+/)
                    
                    for (h in hosts) {
                        def targetHost = h
                        echo "Validating docker-compose on ${targetHost}..."
                        
                        sh """
                            set -eu
                            
                            # Check if docker-compose.yml was generated and is valid
                            if [ "${targetHost}" = "localhost" ] || [ "${targetHost}" = "127.0.0.1" ]; then
                                echo "Checking docker-compose.yml on localhost..."
                                test -f /data/docker-compose/docker-compose.yml || { echo "ERROR: docker-compose.yml not found on localhost"; exit 1; }
                                docker compose -f /data/docker-compose/docker-compose.yml config >/dev/null || { echo "ERROR: docker-compose.yml invalid on localhost"; exit 1; }
                                echo "✓ docker-compose.yml valid on localhost"
                            else
                                echo "Checking docker-compose.yml on ${targetHost}..."
                                ssh ${targetHost} "test -f /data/docker-compose/docker-compose.yml" || { echo "ERROR: docker-compose.yml not found on ${targetHost}"; exit 1; }
                                ssh ${targetHost} "docker compose -f /data/docker-compose/docker-compose.yml config >/dev/null" || { echo "ERROR: docker-compose.yml invalid on ${targetHost}"; exit 1; }
                                echo "✓ docker-compose.yml valid on ${targetHost}"
                            fi
                        """
                    }
                    echo "✓ All docker-compose.yml files validated successfully"
                }
            }
        }

        // ----- Post-deploy verification (opt-in via RUN_E2E, report-only by default) -----
        // Report-only: on failure the stage is marked UNSTABLE (visible) without failing the
        // build, unless E2E_BLOCKING is set. Keeps the fragile multi-host CI green while the
        // checks bed in. Needs `jq` on the agent for the Gatus gate.
        stage('Verify Gatus Health') {
            when { expression { params.RUN_E2E && env.DO_REDEPLOY == 'true' && params.AUTO_DEPLOY && !params.ONLY_CLEAN } }
            steps {
                script {
                    def hosts = env.TARGET_HOSTS.trim().split(/\s+/)
                    def gate = {
                        for (h in hosts) {
                            def targetHost = h
                            echo "Gatus health gate on ${targetHost}..."
                            sh """
                                set -eu
                                bash "${WORKSPACE}/scripts/verify-deployment.sh" --target ${targetHost} --blocking --timeout 300
                            """
                        }
                    }
                    if (params.E2E_BLOCKING) {
                        gate()
                    } else {
                        catchError(buildResult: 'SUCCESS', stageResult: 'UNSTABLE') { gate() }
                    }
                }
            }
        }

        // ----- Hot-redeploy integrity test (opt-in via TEST_REDEPLOY) -----
        // Proves the production redeploy contract on the freshly deployed stack:
        // re-running the playbooks WITHOUT cleaning must (1) destroy no data,
        // (2) keep nginx serving throughout (graceful reload, no recreate), and
        // (3) leave every previously-running container alone (no config changes
        // => no restarts). Blocking by design: if this fails, redeploy-over-live
        // is broken and must not reach production.
        stage('Hot Redeploy Test') {
            when { expression { params.TEST_REDEPLOY && env.DO_REDEPLOY == 'true' && params.AUTO_DEPLOY && !params.ONLY_CLEAN } }
            steps {
                script {
                    def hosts = env.TARGET_HOSTS.trim().split(/\s+/)

                    // --- Phase A: seed canaries, snapshot containers, start nginx probe (per host) ---
                    for (h in hosts) {
                        def targetHost = h
                        sh("""
                            set -eu
                            phase_a=\$(cat <<'EOF'
                            set -eu
                            echo "==> [redeploy-test] Phase A on \$(hostname)"
                            # File canary in /data (outside compose-managed dirs)
                            date -u +%s | sudo tee /data/.redeploy-canary >/dev/null
                            # MySQL canary: own throwaway schema, no app tables touched.
                            # Root password comes from the container env — never leaves the host.
                            if sudo docker ps --format '{{.Names}}' | grep -qx la_mysql; then
                                sudo docker exec la_mysql sh -c 'mysql -uroot -p"\$MYSQL_ROOT_PASSWORD" -e "
                                  CREATE DATABASE IF NOT EXISTS redeploy_canary;
                                  CREATE TABLE IF NOT EXISTS redeploy_canary.t (id INT PRIMARY KEY, ts BIGINT);
                                  REPLACE INTO redeploy_canary.t VALUES (1, UNIX_TIMESTAMP());"'
                                echo "mysql canary seeded"
                            fi
                            # Snapshot running la_* containers: name, immutable ID, and health state.
                            # A container that is UNHEALTHY before the redeploy is allowed to be recreated
                            # (the redeploy heals it: pre-deploy cleanup removes unhealthy la_* and compose
                            # up recreates it fresh), so Phase C enforces a stable ID only for containers
                            # that were NOT unhealthy here.
                            sudo docker ps --filter "name=la_" --format '{{.Names}} {{.ID}}' | while read -r nm cid; do
                                h=\$(sudo docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "\$nm" 2>/dev/null || echo none)
                                echo "\$nm \$cid \$h"
                            done | sort > /tmp/redeploy-before.txt
                            wc -l /tmp/redeploy-before.txt
                            # Availability probe against local nginx (1s cadence) while the redeploy runs.
                            # We classify by curl exit code, NOT just success/fail, to separate the real
                            # contract (did nginx stop ACCEPTING connections? => DOWN) from mere slowness
                            # under the redeploy's CPU storm (image build + up of ~30 containers + restarts
                            # => SLOW). A graceful reload never refuses a connection; a recreate does. So:
                            #   rc 0                -> OK   (served, even a 502 counts as "nginx is up")
                            #   rc 7/28/35/56       -> DOWN (connection refused/reset/SSL handshake failed:
                            #                                nginx not listening = real downtime)
                            #   rc 28 (timeout)     -> SLOW (host saturated but nginx still up; informational)
                            # --max-time 5 gives a wide margin so a slow-but-served request is not miscounted.
                            sudo rm -f /tmp/redeploy-probe.stop /tmp/redeploy-probe.log
                            if sudo docker ps --format '{{.Names}}' | grep -qx la_nginx; then
                                nohup bash -c 'while [ ! -f /tmp/redeploy-probe.stop ]; do
                                    curl -sk -o /dev/null --max-time 5 https://127.0.0.1/; rc=\$?
                                    case "\$rc" in
                                        0)  echo OK ;;
                                        28) echo SLOW ;;
                                        *)  echo "DOWN rc=\$rc" ;;
                                    esac
                                    sleep 1
                                done >> /tmp/redeploy-probe.log' >/dev/null 2>&1 &
                                echo "nginx probe started"
                            fi
EOF
                            )
                            if [ "${targetHost}" = "localhost" ] || [ "${targetHost}" = "127.0.0.1" ]; then
                                bash -c "\$phase_a"
                            else
                                echo "\$phase_a" | ssh -o BatchMode=yes ${targetHost} bash -s
                            fi
                        """.stripIndent())
                    }

                    // --- Phase B: re-run the playbooks, same invocation as 'Run Playbooks', NO cleaning ---
                    def inventoryArg = "-i ${INVENTORY_DIR}/lademo-inventory.ini"
                    if (fileExists("${INVENTORY_DIR}/lademo-local-extras.ini")) {
                        inventoryArg += " -i ${INVENTORY_DIR}/lademo-local-extras.ini"
                    }
                    if (fileExists("${INVENTORY_DIR}/lademo-local-passwords.ini")) {
                        inventoryArg += " -i ${INVENTORY_DIR}/lademo-local-passwords.ini"
                    }
                    // Same skip list (params + active topology): a different set would
                    // legitimately add/remove services and invalidate the
                    // container-stability assertion below.
                    def skipArg = ''
                    def skipList = []
                    if (params.SKIP_SERVICES?.trim()) { skipList += params.SKIP_SERVICES.tokenize(',') }
                    if (env.TOPOLOGY_SKIP_SERVICES?.trim()) { skipList += env.TOPOLOGY_SKIP_SERVICES.tokenize(',') }
                    skipList = skipList.collect { it.trim() }.findAll { it }.unique()
                    if (skipList) {
                        skipArg = " --extra-vars '" + groovy.json.JsonOutput.toJson([skip_services: skipList]) + "'"
                    }
                    sh """
                        set -eu
                        export PATH="${VENV_DIR}/bin:\$PATH"
                        export ANSIBLE_ROLES_PATH="${WORKSPACE}/ala-install/ansible/roles:${WORKSPACE}/roles"
                        export ANSIBLE_FORCE_COLOR=true
                        export ANSIBLE_STDOUT_CALLBACK=yaml
                        export ANSIBLE_HOST_KEY_CHECKING=False
                        echo "[redeploy-test] Re-running site.yml over the live stack (no clean)..."
                        ansible-playbook playbooks/site.yml ${inventoryArg} --limit docker_compose --extra-vars "auto_deploy=true"${skipArg} -v
                    """

                    // --- Phase C: assert canaries intact, zero probe failures, stable containers ---
                    for (h in hosts) {
                        def targetHost = h
                        sh("""
                            set -eu
                            phase_c=\$(cat <<'EOF'
                            set -eu
                            echo "==> [redeploy-test] Phase C on \$(hostname)"
                            rc=0
                            # Stop the probe and judge availability
                            sudo touch /tmp/redeploy-probe.stop; sleep 2
                            if [ -f /tmp/redeploy-probe.log ]; then
                                total=\$(wc -l < /tmp/redeploy-probe.log)
                                down=\$(grep -c DOWN /tmp/redeploy-probe.log || true)
                                slow=\$(grep -c SLOW /tmp/redeploy-probe.log || true)
                                echo "nginx probe: \$down down (refused/reset) / \$slow slow (>5s) / \$total samples"
                                # Only connection refusal/reset counts as downtime — nginx stopped accepting
                                # connections (a recreate/stop). SLOW = host saturated but nginx still serving.
                                if [ "\$down" -gt 0 ]; then echo "FAIL: nginx refused connections during redeploy (\$down samples)"; rc=1; fi
                            fi
                            # File canary
                            if sudo test -f /data/.redeploy-canary; then
                                echo "PASS: file canary preserved"
                            else
                                echo "FAIL: file canary deleted (/data was touched!)"; rc=1
                            fi
                            # MySQL canary
                            if sudo docker ps --format '{{.Names}}' | grep -qx la_mysql; then
                                n=\$(sudo docker exec la_mysql sh -c 'mysql -N -uroot -p"\$MYSQL_ROOT_PASSWORD" -e "SELECT COUNT(*) FROM redeploy_canary.t;"' 2>/dev/null || echo 0)
                                if [ "\$n" = "1" ]; then echo "PASS: mysql canary preserved"; else echo "FAIL: mysql canary lost (count=\$n)"; rc=1; fi
                            fi
                            # Every container that was running AND not-unhealthy BEFORE must still run
                            # with the SAME ID. Containers that were unhealthy before are allowed to be
                            # recreated (the redeploy heals them), so they are skipped here — this keeps
                            # the contract test focused on healthy containers and decouples it from the
                            # OIDC boot-ordering churn (collectory/logger/spatial-hub can boot unhealthy).
                            sudo docker ps --filter "name=la_" --format '{{.Names}} {{.ID}}' | sort > /tmp/redeploy-after.txt
                            while read -r name id health; do
                                if [ "\$health" = "unhealthy" ]; then
                                    echo "SKIP: \$name was unhealthy before redeploy (recreation allowed)"; continue
                                fi
                                if ! grep -q "^\$name \$id\$" /tmp/redeploy-after.txt; then
                                    echo "FAIL: container \$name was recreated or stopped (was \$id)"; rc=1
                                fi
                            done < /tmp/redeploy-before.txt
                            [ "\$rc" -eq 0 ] && echo "PASS: all pre-existing containers untouched"
                            # Cleanup canaries and probe artifacts
                            sudo rm -f /data/.redeploy-canary /tmp/redeploy-probe.stop /tmp/redeploy-probe.log /tmp/redeploy-before.txt /tmp/redeploy-after.txt
                            if sudo docker ps --format '{{.Names}}' | grep -qx la_mysql; then
                                sudo docker exec la_mysql sh -c 'mysql -uroot -p"\$MYSQL_ROOT_PASSWORD" -e "DROP DATABASE IF EXISTS redeploy_canary;"' || true
                            fi
                            exit \$rc
EOF
                            )
                            if [ "${targetHost}" = "localhost" ] || [ "${targetHost}" = "127.0.0.1" ]; then
                                bash -c "\$phase_c"
                            else
                                echo "\$phase_c" | ssh -o BatchMode=yes ${targetHost} bash -s
                            fi
                        """.stripIndent())
                    }
                    echo "✓ Hot redeploy test passed: no data loss, no nginx downtime, containers stable"
                }
            }
        }

        // ----- Airflow ingestion e2e (opt-in via RUN_AIRFLOW_INGEST) -----
        // Runs against the ALREADY-RUNNING stack — NOT gated on DO_REDEPLOY — so a
        // real ingestion can be tested without a full redeploy. Ingests a tiny fixed
        // DwCA through the pipeline and asserts records in Solr + biocache; that data
        // also seeds the Cypress biocache/species suites below (empty index = useless).
        // Report-only (UNSTABLE on failure) unless E2E_BLOCKING.
        stage('Airflow Ingest E2E') {
            when { expression { params.RUN_AIRFLOW_INGEST && params.AUTO_DEPLOY && !params.ONLY_CLEAN } }
            steps {
                script {
                    def hosts = env.TARGET_HOSTS.trim().split(/\s+/)
                    def mode = params.E2E_BLOCKING ? '--blocking' : '--report-only'
                    def run = {
                        def ran = false
                        for (h in hosts) {
                            def targetHost = h
                            // Only the host actually running la_airflow does the ingest; skip the rest.
                            def hasAirflow = sh(returnStatus: true, script: """
                                ssh -o BatchMode=yes -o StrictHostKeyChecking=no ${targetHost} \
                                  "docker inspect -f '{{.State.Running}}' la_airflow 2>/dev/null | grep -q true"
                            """) == 0
                            if (!hasAirflow) { echo "No la_airflow on ${targetHost}; skipping."; continue }
                            ran = true
                            echo "Airflow ingest e2e on ${targetHost}..."
                            sh """
                                set -eu
                                ssh -o BatchMode=yes -o StrictHostKeyChecking=no ${targetHost} "mkdir -p /tmp/ingest-e2e"
                                scp -o BatchMode=yes -o StrictHostKeyChecking=no "${WORKSPACE}/scripts/e2e-airflow-ingest.sh" ${targetHost}:/tmp/ingest-e2e/
                                scp -o BatchMode=yes -o StrictHostKeyChecking=no -r "${WORKSPACE}/e2e/fixtures/dr-test" ${targetHost}:/tmp/ingest-e2e/
                                ssh -o BatchMode=yes -o StrictHostKeyChecking=no ${targetHost} \
                                  "FIXTURE_DIR=/tmp/ingest-e2e/dr-test TIMEOUT=1800 bash /tmp/ingest-e2e/e2e-airflow-ingest.sh ${mode}"
                            """
                        }
                        if (!ran) { echo "la_airflow not found on any target host — nothing ingested." }
                    }
                    if (params.E2E_BLOCKING) {
                        run()
                    } else {
                        catchError(buildResult: 'SUCCESS', stageResult: 'UNSTABLE') { run() }
                    }
                }
            }
        }

        stage('E2E Smoke Tests') {
            // Run after a redeploy OR after an Airflow ingest against the already-running stack:
            // the ingest (stage above) seeds the biocache/species suites, so the smoke should
            // consume that fresh data even when DO_REDEPLOY is false (ingest-only run).
            when { expression { params.RUN_E2E && (env.DO_REDEPLOY == 'true' || params.RUN_AIRFLOW_INGEST) && params.AUTO_DEPLOY && !params.ONLY_CLEAN } }
            steps {
                script {
                    def hosts = env.TARGET_HOSTS.trim().split(/\s+/)
                    def targetHost = hosts[0]
                    // Cypress consumes the inventory-generated manifest — build the docker cmd once.
                    def body = {
                        // Fetch the manifest from a target host into the workspace for the container.
                        sh """
                            set -eu
                            if [ "${targetHost}" = "localhost" ] || [ "${targetHost}" = "127.0.0.1" ]; then
                                cp /data/docker-compose/e2e-targets.json "${WORKSPACE}/e2e/e2e-targets.json"
                            else
                                ssh -o BatchMode=yes -o StrictHostKeyChecking=no ${targetHost} "cat /data/docker-compose/e2e-targets.json" > "${WORKSPACE}/e2e/e2e-targets.json"
                            fi
                        """
                        // For the login smoke (ENABLE_AUTH_TESTS), read the CAS admin credentials from
                        // the inventory's local-passwords.ini — the email var plus the plaintext password
                        // the generator leaves in a comment ("random password: ..."). Passed by name and
                        // never echoed (set +x); no Jenkins secret needed.
                        sh """
                            set -eu
                            set +x
                            if [ "${params.ENABLE_AUTH_TESTS}" = "true" ]; then
                                PWFILE="${INVENTORY_DIR}/lademo-local-passwords.ini"
                                if [ -f "\$PWFILE" ]; then
                                    export CYPRESS_LADEMO_USERNAME="\$(sed -nE 's/^[[:space:]]*cas_first_admin_email[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\\1/p' "\$PWFILE" | head -1)"
                                    export CYPRESS_LADEMO_PASSWORD="\$(sed -nE 's/.*random password:[[:space:]]*([^[:space:]]+).*/\\1/p' "\$PWFILE" | head -1)"
                                    [ -n "\$CYPRESS_LADEMO_PASSWORD" ] || echo "WARN: admin password not found in comments of \$PWFILE; login test will fail"
                                else
                                    echo "WARN: \$PWFILE not found; login test will fail"
                                fi
                            fi
                            # Clean prior JUnit results INSIDE the container (runs as root) so the root-owned
                            # results-*.xml written by earlier cypress runs are actually removed — the jenkins
                            # user can't rm them, so otherwise junit republishes the last good run's stale
                            # results and freezes the same failures at an ever-growing age. Then run fresh, so
                            # junit reflects THIS build (or empty -> honest -> UNSTABLE, not stale-green).
                            docker run --rm -v "${WORKSPACE}/e2e:/e2e" -w /e2e -e CYPRESS_TARGET_ENV=lademo -e CYPRESS_TARGETS_FILE=/e2e/e2e-targets.json -e CYPRESS_LADEMO_USERNAME -e CYPRESS_LADEMO_PASSWORD -e CYPRESS_ENABLE_AUTH_TESTS=${params.ENABLE_AUTH_TESTS} cypress/browsers:latest sh -c 'rm -rf /e2e/results; npm ci && npx cypress run'
                        """
                    }
                    if (params.E2E_BLOCKING) {
                        body()
                    } else {
                        catchError(buildResult: 'SUCCESS', stageResult: 'UNSTABLE') { body() }
                    }
                }
            }
            post {
                always {
                    junit allowEmptyResults: true, testResults: 'e2e/results/*.xml'
                    archiveArtifacts artifacts: 'e2e/cypress/screenshots/**, e2e/cypress/videos/**', allowEmptyArchive: true
                }
            }
        }
    }

    post {
        always {
            echo "Pipeline finished."
        }
        success {
            echo "Deployment successful!"
        }
        failure {
            echo "Deployment failed. Check logs."
        }
    }
}

