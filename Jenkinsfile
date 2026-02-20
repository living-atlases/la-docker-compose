pipeline {
    agent any

    options {
        disableConcurrentBuilds()
        timestamps()
        ansiColor('xterm')
    }

    parameters {
        booleanParam(
            name: 'CLEAN_MACHINE',
            defaultValue: false,
            description: 'Stop services and wipe /data before running'
        )
        string(
            name: 'ALA_INSTALL_BRANCH',
            defaultValue: 'master',
            description: 'Branch of ala-install to use'
        )
        booleanParam(
            name: 'AUTO_DEPLOY',
            defaultValue: true,
            description: 'Automatically start containers after generating configuration'
        )
    }

    environment {
        ALA_INSTALL_DIR = "${workspace}/../ala-install"
        ANSIBLE_CONFIG = "${workspace}/ansible.cfg"
    }

    stages {
        stage('Cleanup') {
            when { expression { params.CLEAN_MACHINE } }
            steps {
                script {
                    sh '''
                        set +e
                        echo "==> Stopping services and removing volumes"
                        if [ -d /data/docker-compose ]; then
                            cd /data/docker-compose && docker-compose down -v || true
                        fi
                        
                        echo "==> Cleaning /data directory"
                        sudo rm -rf /data/docker-compose /data/mysql /data/mongodb /data/solr /data/cassandra /data/elasticsearch || true
                    '''
                }
            }
        }

        stage('Update Dependencies') {
            steps {
                script {
                    sh """
                        if [ ! -d "${ALA_INSTALL_DIR}" ]; then
                            git clone https://github.com/AtlasOfLivingAustralia/ala-install.git "${ALA_INSTALL_DIR}"
                        fi
                        cd "${ALA_INSTALL_DIR}"
                        git fetch --prune origin
                        git checkout ${params.ALA_INSTALL_BRANCH}
                        git pull origin ${params.ALA_INSTALL_BRANCH}
                    """
                }
            }
        }

        stage('Generate Configuration') {
            steps {
                script {
                    def playbook = params.AUTO_DEPLOY ? 'playbooks/site.yml' : 'playbooks/config-gen.yml'
                    sh "ansible-playbook ${playbook} -i inventories/local/hosts.ini"
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
