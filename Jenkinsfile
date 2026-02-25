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
        ALA_DIR = "${BASE_DIR}/ala-install"
        GENERATOR_DIR = "${BASE_DIR}/generator-living-atlas"
        
        INVENTORY_PARENT_DIR = "${BASE_DIR}/lademo"
        INVENTORY_DIR = "${INVENTORY_PARENT_DIR}/lademo-inventories"

        VENV_DIR = "${BASE_DIR}/.venv-ansible"
        ANSIBLE_CONFIG = "${workspace}/ansible.cfg"

        ALA_GIT_URL = "https://github.com/vjrj/ala-install.git"
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
            name: 'ALA_INSTALL_BRANCH',
            defaultValue: 'docker-compose-poc',
            description: 'Branch of ala-install to use'
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
                                
                                # 1. Stop containers if docker is present
                                if [ -d /data/docker-compose ] && command -v docker >/dev/null 2>&1; then
                                    echo "Stopping existing containers..."
                                    sudo find /data/docker-compose -maxdepth 2 -name "docker-compose.yml" -execdir docker compose down -v \\; || true
                                fi
                                
                                # 2. Stop docker service
                                if command -v systemctl >/dev/null 2>&1; then
                                    sudo systemctl stop docker containerd 2>/dev/null || true
                                fi

                                # 3. Wait for apt/dpkg locks
                                i=0
                                while pgrep -x apt-get >/dev/null 2>&1 || pgrep -x apt >/dev/null 2>&1 || pgrep -x dpkg >/dev/null 2>&1 || pgrep -f unattended-upgrades >/dev/null 2>&1; do
                                    i=\$((i+1))
                                    if [ "\$i" -ge 60 ]; then echo "ERROR: apt busy for too long"; exit 1; fi
                                    sleep 5
                                done

                                # 4. Wipe /data (preserving lost+found)
                                if [ -d /data ]; then
                                    echo "Cleaning /data..."
                                    sudo find /data -mindepth 1 -maxdepth 1 -not -name lost+found -not -name var-lib-containerd -print -exec rm -rf -- {} + || true
                                fi

                                # 5. Purge docker packages
                                if command -v apt-get >/dev/null 2>&1; then
                                    sudo apt-get remove -y docker-ce docker-ce-cli docker.io containerd runc || true
                                    sudo apt-get autoremove -y || true
                                fi

                                 # 6. Clean residual docker config and keys
                                 sudo rm -rf /etc/docker /etc/systemd/system/docker.service.d || true
                                 sudo rm -f /var/run/docker.sock || true
                                 sudo rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc /etc/apt/trusted.gpg.d/download.docker.com.asc || true
                                 
                                 # 7. Reload systemd after cleaning docker units
                                 if command -v systemctl >/dev/null 2>&1; then
                                     sudo systemctl daemon-reload 2>/dev/null || true
                                 fi
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

        stage('Prepare environment') {
            when { expression { !params.ONLY_CLEAN } }
            steps {
                sh """
                    set -eu
                    
                    echo "Creating base directories..."
                    mkdir -p "${BASE_DIR}" "${ALA_DIR}" "${GENERATOR_DIR}" "${INVENTORY_PARENT_DIR}" "${INVENTORY_DIR}"
                    
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
                parallel(
                    'Update ala-install': {
                        sh """
                            set -eu
                            if [ ! -d "${ALA_DIR}/.git" ]; then
                                rm -rf "${ALA_DIR}"
                                git clone "${env.ALA_GIT_URL}" "${ALA_DIR}"
                            fi
                            cd "${ALA_DIR}"
                            git fetch --prune origin
                            git checkout -B "${params.ALA_INSTALL_BRANCH}" "origin/${params.ALA_INSTALL_BRANCH}"
                            git reset --hard "origin/${params.ALA_INSTALL_BRANCH}"
                            git clean -fdx
                        """
                    },
                    'Update generator-living-atlas': {
                        sh """
                            set -eu
                            if [ ! -d "${GENERATOR_DIR}/.git" ]; then
                                rm -rf "${GENERATOR_DIR}"
                                git clone "${env.GENERATOR_GIT_URL}" "${GENERATOR_DIR}"
                            fi
                            cd "${GENERATOR_DIR}"
                            git fetch --prune origin
                            git checkout -B "${params.GENERATOR_BRANCH}" "origin/${params.GENERATOR_BRANCH}"
                            git reset --hard "origin/${params.GENERATOR_BRANCH}"
                            git clean -fdx
                        """
                    }
                )
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
                                ALA_SHA=\$(cd "${ALA_DIR}" && git rev-parse HEAD)
                                GEN_SHA=\$(cd "${GENERATOR_DIR}" && git rev-parse HEAD)
                                SELF_SHA=\$(git rev-parse HEAD)
                                
                                ALA_FILE="${BASE_DIR}/.last_sha_ala"
                                GEN_FILE="${BASE_DIR}/.last_sha_gen"
                                SELF_FILE="${BASE_DIR}/.last_sha_self"
                                
                                CHANGED="false"
                                if [ ! -f "\$ALA_FILE" ] || [ "\$(cat "\$ALA_FILE")" != "\$ALA_SHA" ]; then echo "\$ALA_SHA" > "\$ALA_FILE"; CHANGED="true"; fi
                                if [ ! -f "\$GEN_FILE" ] || [ "\$(cat "\$GEN_FILE")" != "\$GEN_SHA" ]; then echo "\$GEN_SHA" > "\$GEN_FILE"; CHANGED="true"; fi
                                if [ ! -f "\$SELF_FILE" ] || [ "\$(cat "\$SELF_FILE")" != "\$SELF_SHA" ]; then echo "\$SELF_SHA" > "\$SELF_FILE"; CHANGED="true"; fi
                                
                                echo "\$CHANGED|\$ALA_SHA|\$GEN_SHA|\$SELF_SHA"
                            """,
                            returnStdout: true
                        ).trim().split('\\|')

                        env.DO_REDEPLOY = (results[0] == 'true') ? 'true' : 'false'
                        echo "ALA_SHA:  ${results[1]}"
                        echo "GEN_SHA:  ${results[2]}"
                        echo "SELF_SHA: ${results[3]}"
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
                    
                    # Use npm ci if package-lock.json exists, otherwise npm install
                    if [ -f package-lock.json ]; then
                        echo "Found package-lock.json, using npm ci for reproducibility..."
                        \$NPM ci --no-audit --no-fund
                    else
                        echo "No package-lock.json found, using npm install..."
                        \$NPM install --no-audit --no-fund --ignore-scripts
                    fi
                    
                    # Install yeoman-generator in the generator checkout
                    echo "Installing yeoman-generator in generator directory..."
                    \$NPM install --no-audit --no-fund yeoman-generator
                    
                    # Verify yeoman-generator is available
                    test -d node_modules/yeoman-generator || { echo "ERROR: yeoman-generator not installed"; exit 1; }
                    echo "✓ yeoman-generator installed successfully"
                    
                    # Verify generator can import yeoman-generator
                    echo "Verifying yeoman-generator can be imported..."
                    node -e "import('yeoman-generator').then(()=>console.log('✓ yeoman-generator: OK')).catch(e=>{console.error(e); process.exit(1)})"
                    
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
                    
                    echo "Running generator..."
                    node ./node_modules/yo/lib/cli.js living-atlas --replay-dont-ask --force
                    
                    echo "Verifying generated inventory..."
                    test -f "${INVENTORY_DIR}/lademo-inventory.ini" || { echo "ERROR: inventory not generated"; exit 1; }
                    ls -lh "${INVENTORY_DIR}/lademo-inventory.ini"
                    echo "✓ Inventory generated successfully"
                """
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
                    
                    sh """
                        set -eu
                        
                        export PATH="${VENV_DIR}/bin:\$PATH"
                        export ANSIBLE_FORCE_COLOR=true
                        export ANSIBLE_STDOUT_CALLBACK=yaml
                        export ANSIBLE_HOST_KEY_CHECKING=False
                        
                        echo "Ansible version:"
                        ansible-playbook --version
                        
                        echo "Running playbook against docker_compose group (all hosts)..."
                        ansible-playbook ${playbook} ${inventoryArg} --limit docker_compose --extra-vars "auto_deploy=${params.AUTO_DEPLOY}" -vv
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

