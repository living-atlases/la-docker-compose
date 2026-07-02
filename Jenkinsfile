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
        // TARGET_HOSTS can be overridden in Jenkins job
        TARGET_HOSTS = "gbif-es-docker-cluster-2023-1 gbif-es-docker-cluster-2023-2 gbif-es-docker-cluster-2023-3"

        BASE_DIR = "${env.HOME}/ala-install-docker-tests"
        GENERATOR_DIR = "${BASE_DIR}/generator-living-atlas"
        
        INVENTORY_PARENT_DIR = "${BASE_DIR}/lademo"
        INVENTORY_DIR = "${INVENTORY_PARENT_DIR}/lademo-inventories"

        VENV_DIR = "${BASE_DIR}/.venv-ansible"

        GENERATOR_GIT_URL = "https://github.com/living-atlases/generator-living-atlas.git"
    }

    parameters {
        booleanParam(
            name: 'FORCE_REDEPLOY',
            defaultValue: false,
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
            defaultValue: false,
            description: 'Run post-deploy verification (Gatus health gate + Cypress smoke). Report-only.'
        )
        booleanParam(
            name: 'E2E_BLOCKING',
            defaultValue: false,
            description: 'If true, a verification failure fails the build. If false, it only marks the stage UNSTABLE.'
        )
        booleanParam(
            name: 'ENABLE_AUTH_TESTS',
            defaultValue: false,
            description: 'Include the CAS/OIDC login smoke test. Single toggle: also seeds the demo/demo user in this deploy (demo-only, never on production).'
        )
    }

    stages {
        stage('Clean machines') {
            when { expression { params.CLEAN_MACHINE || params.ONLY_CLEAN } }
            steps {
                script {
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

                    if (params.FORCE_REDEPLOY || (isManual && !isCron)) {
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
                      echo "Refreshing base-branding (git pull)..."
                      git -C "${INVENTORY_PARENT_DIR}/lademo-branding" pull --autostash --no-edit || echo "WARN: base-branding pull failed (continuing with replayed tree)"
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
                    def skipArg = ''
                    if (params.SKIP_SERVICES?.trim()) {
                        def skipList = params.SKIP_SERVICES.split(',').collect { it.trim() }.findAll { it }
                        skipArg = " --extra-vars '" + groovy.json.JsonOutput.toJson([skip_services: skipList]) + "'"
                        echo "Skipping services: ${skipList}"
                    }

                    // One toggle: enabling the login smoke test also seeds the demo/demo user
                    // in this deploy (init-e2e-user.yml). Demo-only; never set on production.
                    def authArg = ''
                    if (params.ENABLE_AUTH_TESTS) {
                        authArg = " --extra-vars 'e2e_demo_user_enabled=true'"
                        echo "ENABLE_AUTH_TESTS: seeding demo/demo login user"
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
                        ansible-playbook ${playbook} ${inventoryArg} --limit docker_compose --extra-vars "auto_deploy=${params.AUTO_DEPLOY}"${skipArg}${authArg} -vv
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

        stage('E2E Smoke Tests') {
            when { expression { params.RUN_E2E && env.DO_REDEPLOY == 'true' && params.AUTO_DEPLOY && !params.ONLY_CLEAN } }
            steps {
                script {
                    def hosts = env.TARGET_HOSTS.trim().split(/\s+/)
                    def targetHost = hosts[0]
                    // Cypress consumes the inventory-generated manifest — build the docker cmd once.
                    def dockerCmd = """set -eu
                        docker run --rm -v "${WORKSPACE}/e2e:/e2e" -w /e2e -e CYPRESS_TARGET_ENV=lademo -e CYPRESS_TARGETS_FILE=/e2e/e2e-targets.json -e CYPRESS_LADEMO_USERNAME -e CYPRESS_LADEMO_PASSWORD -e CYPRESS_ENABLE_AUTH_TESTS=${params.ENABLE_AUTH_TESTS} cypress/browsers:latest sh -c 'npm ci && npx cypress run'"""
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
                        // The login smoke (ENABLE_AUTH_TESTS) uses the seeded demo/demo user by
                        // default — no Jenkins secret needed. Override with CYPRESS_LADEMO_* if wanted.
                        sh dockerCmd
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

