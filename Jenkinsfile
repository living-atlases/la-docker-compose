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

    parameters {
        booleanParam(
            name: 'FORCE_REDEPLOY',
            defaultValue: false,
            description: 'Run inventories + redeploy even if no changes are detected'
        )
        booleanParam(
            name: 'CLEAN_MACHINE',
            defaultValue: false,
            description: 'Wipe /data (except lost+found) and purge Docker before running'
        )
        booleanParam(
            name: 'ONLY_CLEAN',
            defaultValue: false,
            description: 'Only clean machines and stop'
        )
        string(
            name: 'ALA_INSTALL_BRANCH',
            defaultValue: 'master',
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

    environment {
        TARGET_HOSTS = "localhost" // Can be overridden in Jenkins job

        BASE_DIR = "${workspace}/.."
        ALA_DIR = "${BASE_DIR}/ala-install"
        GENERATOR_DIR = "${BASE_DIR}/generator-living-atlas"
        
        VENV_DIR = "${BASE_DIR}/.venv-ansible"
        ANSIBLE_CONFIG = "${workspace}/ansible.cfg"

        ALA_GIT_URL = "https://github.com/AtlasOfLivingAustralia/ala-install.git"
        GENERATOR_GIT_URL = "https://github.com/living-atlases/generator-living-atlas.git"
    }

    stages {
        stage('Clean machines') {
            when { expression { params.CLEAN_MACHINE || params.ONLY_CLEAN } }
            steps {
                script {
                    def hosts = env.TARGET_HOSTS.trim().split(/\s+/)
                    
                    for (h in hosts) {
                        def targetHost = h
                        if (targetHost != 'localhost') {
                            sh("""
                                set +e
                                ssh-keygen -f "\$HOME/.ssh/known_hosts" -R "${targetHost}" >/dev/null 2>&1
                                ip=\$(ssh -G "${targetHost}" | awk '/^hostname /{print \$2; exit}')
                                if [ -n "\$ip" ]; then
                                    ssh-keygen -f "\$HOME/.ssh/known_hosts" -R "\$ip" >/dev/null 2>&1
                                    ssh-keyscan -H "\$ip" >> "\$HOME/.ssh/known_hosts" 2>/dev/null
                                fi
                                ssh-keyscan -H "${targetHost}" >> "\$HOME/.ssh/known_hosts" 2>/dev/null
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
                                if [ "${targetHost}" = "localhost" ]; then
                                    bash -s <<'EOF'
                                    set -eu
                                    echo "==> Cleaning on local host"
                                    if [ -d /data/docker-compose ]; then
                                        sudo find /data/docker-compose -maxdepth 2 -name "docker-compose.yml" -execdir docker compose down -v \\; || true
                                    fi
                                    if command -v systemctl >/dev/null 2>&1; then
                                        sudo systemctl stop docker containerd 2>/dev/null || true
                                    fi
                                    if [ -d /data ]; then
                                        sudo find /data -mindepth 1 -maxdepth 1 -not -name lost+found -print -exec rm -rf -- {} + || true
                                    fi
                                    if command -v apt-get >/dev/null 2>&1; then
                                        sudo apt-get remove -y docker-ce docker-ce-cli docker.io containerd runc || true
                                        sudo apt-get autoremove -y || true
                                    fi
                                    sudo rm -rf /etc/docker /etc/systemd/system/docker.service.d || true
                                    sudo rm -f /var/run/docker.sock || true
                                    sudo rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc /etc/apt/trusted.gpg.d/dowload.docker.com.asc /etc/apt/trusted.gpg.d/download.docker.com.asc || true
EOF
                                else
                                    cat <<'EOF' | ssh ${targetHost} bash -s
                                    set -eu
                                    echo "==> Cleaning on \$(hostname)"
                                    if sudo -n true 2>/dev/null; then
                                        if [ -d /data/docker-compose ] && command -v docker >/dev/null 2>&1; then
                                            sudo find /data/docker-compose -maxdepth 2 -name "docker-compose.yml" -execdir docker compose down -v \\; || true
                                        fi
                                        if command -v systemctl >/dev/null 2>&1; then
                                            sudo systemctl stop docker containerd 2>/dev/null || true
                                        fi
                                        if [ -d /data ]; then
                                            sudo find /data -mindepth 1 -maxdepth 1 -not -name lost+found -print -exec rm -rf -- {} + || true
                                        fi
                                        if command -v apt-get >/dev/null 2>&1; then
                                            sudo apt-get remove -y docker-ce docker-ce-cli docker.io containerd runc || true
                                            sudo apt-get autoremove -y || true
                                        fi
                                        sudo rm -rf /etc/docker /etc/systemd/system/docker.service.d || true
                                        sudo rm -f /var/run/docker.sock || true
                                        sudo rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc /etc/apt/trusted.gpg.d/dowload.docker.com.asc /etc/apt/trusted.gpg.d/download.docker.com.asc || true
                                    else
                                        echo "WARNING: no passwordless sudo on \$(hostname)"
                                    fi
EOF
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
                    mkdir -p "${BASE_DIR}" "${ALA_DIR}" "${GENERATOR_DIR}"
                    if [ ! -d "${VENV_DIR}" ]; then
                        python3 -m venv "${VENV_DIR}"
                    fi
                    "${VENV_DIR}/bin/pip" install --upgrade pip
                    "${VENV_DIR}/bin/pip" install ansible
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
                            git checkout "${params.ALA_INSTALL_BRANCH}"
                            git pull origin "${params.ALA_INSTALL_BRANCH}"
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
                            git checkout "${params.GENERATOR_BRANCH}"
                            git pull origin "${params.GENERATOR_BRANCH}"
                        """
                    }
                )
            }
        }

        stage('Decide redeploy') {
            when { expression { !params.ONLY_CLEAN } }
            steps {
                script {
                    if (params.FORCE_REDEPLOY) {
                        env.DO_REDEPLOY = 'true'
                        echo 'FORCE_REDEPLOY is true.'
                        return
                    }

                    def changelog = sh(
                        script: """
                            set -eu
                            ALA_SHA=\$(cd "${ALA_DIR}" && git rev-parse HEAD)
                            GEN_SHA=\$(cd "${GENERATOR_DIR}" && git rev-parse HEAD)
                            SELF_SHA=\$(git rev-parse HEAD)
                            
                            STATE_FILE="${BASE_DIR}/.last_shas"
                            OLD_SHAS=""
                            if [ -f "\$STATE_FILE" ]; then OLD_SHAS=\$(cat "\$STATE_FILE"); fi
                            
                            NEW_SHAS="\$ALA_SHA \$GEN_SHA \$SELF_SHA"
                            if [ "\$NEW_SHAS" = "\$OLD_SHAS" ]; then
                                echo "nochange"
                            else
                                echo "\$NEW_SHAS" > "\$STATE_FILE"
                                echo "changed"
                            fi
                        """,
                        returnStdout: true
                    ).trim()

                    env.DO_REDEPLOY = (changelog == 'changed') ? 'true' : 'false'
                    echo "Redeploy needed: ${env.DO_REDEPLOY}"
                }
            }
        }

        stage('Install generator deps') {
            when { expression { env.DO_REDEPLOY == 'true' && !params.ONLY_CLEAN } }
            steps {
                sh '''
                    set -eu
                    cd "$GENERATOR_DIR"
                    npm install --no-audit --no-fund
                    npm install --no-audit --no-fund yo yeoman-generator
                '''
            }
        }

        stage('Regenerate inventories') {
            when { expression { env.DO_REDEPLOY == 'true' && !params.ONLY_CLEAN } }
            steps {
                script {
                    // Check if we have enough info to run Yeoman
                    def replayFile = "${BASE_DIR}/living-atlas-replay.json"
                    if (fileExists(replayFile)) {
                        sh """
                            set -eu
                            cp "${replayFile}" "${workspace}/.yo-rc.json"
                            node "${GENERATOR_DIR}/node_modules/yo/lib/cli.js" living-atlas --replay-dont-ask --force
                        """
                    } else {
                        echo "No replay file found at ${replayFile}, skipping Yeoman generation."
                    }
                }
            }
        }

        stage('Run Playbooks') {
            when { expression { env.DO_REDEPLOY == 'true' && !params.ONLY_CLEAN } }
            steps {
                script {
                    def playbook = params.AUTO_DEPLOY ? 'playbooks/site.yml' : 'playbooks/config-gen.yml'
                    sh """
                        export PATH="${VENV_DIR}/bin:\$PATH"
                        export ANSIBLE_FORCE_COLOR=true
                        export ANSIBLE_STDOUT_CALLBACK=yaml
                        
                        ansible-playbook ${playbook} -i inventories/local/hosts.ini
                    """
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

