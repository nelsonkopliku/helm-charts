#!/bin/bash

set -e

readonly ARGS=("$@")
readonly PROGNAME="./install-server.sh"
TRENTO_SERVER_CHART_VERSION=${TRENTO_SERVER_CHART_VERSION:-"1.0.0"}
TRENTO_WEB_VERSION=${TRENTO_WEB_VERSION:-"1.0.0"}
TRENTO_RUNNER_VERSION=${TRENTO_RUNNER_VERSION:-"1.0.0"}
TRENTO_ROLLING_VERSION=${TRENTO_ROLLING_VERSION:-"rolling"}

usage() {
    cat <<-EOF
    usage: $PROGNAME options

    Install Trento Server

    OPTIONS:
        -p, --private-key           Private SSH key used by the runner to connect to the hosts.
        -m, --enable-mtls           Enable mTLS secure communication between the agent and the server.
        -c, --cert                  The path to the TLS certificate file. Required if --enable-mtls is set.
        -k, --key                   The path to the TLS key file. Required if --enable-mtls is set.
        -a, --ca                    The path to the TLS CA file. Required if --enable-mtls is set.
        -n, --enable-alerting       Enable Alerting feature.
        -f, --smtp-server           The SMTP server designated to send alerting emails.
        -g, --smtp-port             The port on SMT server.
        -i, --smtp-user             Username to access SMTP server.
        -l, --smtp-password         Password to access SMTP server.
        -o, --alerting-recipient    Recipient email for alerting notifications.
        -w, --admin-password        admin user password.
        -r, --rolling               Use the rolling version instead of the stable one.
        -e, --existing-k8s          Deploy to an existing kubernetes cluster (don't deploy k3s)
        -u, --use-registry          Container registry to pull the images from
        -h, --help                  Print this help.

    Example:
       $PROGNAME --private-key ./id_rsa_runner
EOF
}

cmdline() {
    local arg=

    for arg; do
        local delim=""
        case "$arg" in
        --private-key) args="${args}-p " ;;
        --enable-mtls) args="${args}-m " ;;
        --cert) args="${args}-c " ;;
        --key) args="${args}-k " ;;
        --ca) args="${args}-a " ;;
        --enable-alerting) args="${args}-n " ;;
        --smtp-server) args="${args}-f " ;;
        --smtp-port) args="${args}-g " ;;
        --smtp-user) args="${args}-i " ;;
        --smtp-password) args="${args}-l " ;;
        --alerting-recipient) args="${args}-o " ;;
        --admin-password) args="${args}-w " ;;
        --rolling) args="${args}-r " ;;
        --use-registry) args="${args}-u " ;;
        --existing-k8s) args="${args}-e " ;;
        --help) args="${args}-h " ;;

        # pass through anything else
        *)
            [[ "${arg:0:1}" == "-" ]] || delim="\""
            args="${args}${delim}${arg}${delim} "
            ;;
        esac
    done

    eval set -- "$args"

    while getopts "p:c:k:a:f:g:i:l:o:mnrw:u:eh" OPTION; do
        case $OPTION in
        h)
            usage
            exit 0
            ;;

        p)
            PRIVATE_KEY=$OPTARG
            ;;

        m)
            ENABLE_MTLS=true
            ;;

        c)
            CERT=$OPTARG
            ;;

        k)
            KEY=$OPTARG
            ;;

        a)
            CA=$OPTARG
            ;;

        n)
            ENABLE_ALERTING=true
            ;;

        f)
            SMTP_SERVER=$OPTARG
            ;;

        g)
            SMTP_PORT=$OPTARG
            ;;

        i)
            SMTP_USER=$OPTARG
            ;;

        l)
            SMTP_PASSWORD=$OPTARG
            ;;

        o)
            ALERTING_RECIPIENT=$OPTARG
            ;;

        w)
            ADMIN_PASSWORD=$OPTARG
            CONFIRM_ADMIN_PASSWORD=$ADMIN_PASSWORD
            ;;

        r)
            ROLLING=true
            ;;

        u)
            TRENTO_REGISTRY=$OPTARG
            ;;

        e)
            EXISTING_K8S=true
            ;;

        *)
            usage
            exit 0
            ;;
        esac
    done

    set_admin_password
    confirm_admin_password
    set_private_key
    configure_alerting

    if [[ "$ROLLING" == "true" ]]; then
        TRENTO_SERVER_CHART_VERSION=$TRENTO_ROLLING_VERSION
        TRENTO_WEB_VERSION=$TRENTO_ROLLING_VERSION
        TRENTO_RUNNER_VERSION=$TRENTO_ROLLING_VERSION
    fi

    return 0
}

function load_conf() {
    if [ -f /etc/trento/installer.conf ]; then
        echo "Loading installer configuration"
        # shellcheck source=/dev/null
        source /etc/trento/installer.conf
    fi
}

function set_admin_password() {
    if [[ -z "$ADMIN_PASSWORD" ]]; then
        read -rsp "Please provide the password of the \"admin\" user (min 8 characters): " ADMIN_PASSWORD </dev/tty
    fi

    echo

    if [[ ${#ADMIN_PASSWORD} -lt 8 ]]; then
        echo "The admin password should be at least 8 characters, please try again."
        unset ADMIN_PASSWORD
        set_admin_password
    fi
}

function confirm_admin_password() {
    if [[ -z "$CONFIRM_ADMIN_PASSWORD" ]]; then
        read -rsp "Please confirm the password: " CONFIRM_ADMIN_PASSWORD </dev/tty
    fi

    echo

    if [[ $ADMIN_PASSWORD != "$CONFIRM_ADMIN_PASSWORD" ]]; then
        echo "The password don't match, please try again."
        unset CONFIRM_ADMIN_PASSWORD
        confirm_admin_password
    fi
}

function set_private_key() {

    if [[ -z "$PRIVATE_KEY" ]]; then
        read -rp "Please provide the path of the runner private key: " PRIVATE_KEY </dev/tty
    fi

    PRIVATE_KEY=$(normalize_path "$PRIVATE_KEY") || {
        echo "Path to the private key file does not exist, please try again."
        unset PRIVATE_KEY
        set_private_key
    }
}

function configure_mtls() {
    if [[ -n "$ENABLE_MTLS" ]]; then
        if [[ -z "$CERT" ]]; then
            read -rp "Please provide the TLS certificate path: " CERT </dev/tty

        fi
        CERT=$(normalize_path "$CERT") || {
            echo "Path to the TLS cert file does not exist, please try again."
            exit 1
        }

        if [[ -z "$KEY" ]]; then
            read -rp "Please provide the TLS key path: " KEY </dev/tty
        fi
        KEY=$(normalize_path "$KEY") || {
            echo "Path to the TLS key file does not exist, please try again."
            exit 1
        }

        if [[ -z "$CA" ]]; then
            read -rp "Please provide the TLS CA path: " CA </dev/tty
        fi
        CA=$(normalize_path "$CA") || {
            echo "Path to the TLS CA file does not exist, please try again."
            exit 1
        }
    fi
}

function configure_alerting() {
    if [[ -n "$ENABLE_ALERTING" ]]; then
        if [[ -z "$SMTP_SERVER" ]]; then
            read -rp "Please provide the SMTP server host: " SMTP_SERVER </dev/tty
        fi

        if [[ -z "$SMTP_PORT" ]]; then
            read -rp "Please provide the Port of the SMTP server: " SMTP_PORT </dev/tty
        fi

        if [[ -z "$SMTP_USER" ]]; then
            read -rp "Please provide the SMTP user: " SMTP_USER </dev/tty
        fi

        if [[ -z "$SMTP_PASSWORD" ]]; then
            read -rp "Please provide the SMTP password: " SMTP_PASSWORD </dev/tty
        fi

        if [[ -z "$ALERTING_RECIPIENT" ]]; then
            read -rp "Please provide the recipient email for alerting notifications: " ALERTING_RECIPIENT </dev/tty
        fi
    fi
}

function normalize_path() {
    local path=$1
    local absolute_path

    path="${path/#\~/$HOME}"
    absolute_path=$(realpath -q -e "$path") || {
        exit 1
    }

    echo "$absolute_path"
}

check_requirements() {
    local firewalld_status
    firewalld_status="$(systemctl show -p ActiveState firewalld | cut -d'=' -f2)"
    if [ "${firewalld_status}" = "active" ]; then
        echo "firewalld must be turned off to run K3s, please disable it and try again."
        exit 1
    fi
    if ! which curl >/dev/null 2>&1; then
        echo "curl is required by this script, please install it and try again."
        exit 1
    fi
    if ! which unzip >/dev/null 2>&1; then
        echo "unzip is required by this script, please install it and try again."
        exit 1
    fi
    if grep -q "Y" /sys/module/apparmor/parameters/enabled; then
        if ! command -v /sbin/apparmor_parser >/dev/null 1>&1; then
            echo "apparmor_parser is required by k3s when using AppArmor, please install it and try again."
            exit 1
        fi
    fi
}

install_k3s() {
    echo "Installing K3s..."
    curl -sfL https://get.k3s.io | sh >/dev/null
    mkdir -p ~/.kube
    sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
    sudo chown "$USER": ~/.kube/config
    unset KUBECONFIG
}

install_helm() {
    echo "Installing Helm..."
    curl -s https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash >/dev/null
}

update_helm_dependencies() {
    local download_chart=${DOWNLOAD_CHART:-true}
    if [[ "$download_chart" != true ]]; then
        return
    fi
    echo "Updating Helm dependencies..."
    helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null
    helm repo update >/dev/null
}

install_trento_server_chart() {
    local download_chart=${DOWNLOAD_CHART:-true}
    local repo_owner=${TRENTO_REPO_OWNER:-"trento-project"}
    local registry=${TRENTO_REGISTRY:-"ghcr.io/$repo_owner"}
    local runner_image=${TRENTO_RUNNER_IMAGE:-"$registry/trento-runner"}
    local web_image=${TRENTO_WEB_IMAGE:-"$registry/trento-web"}
    local private_key=${PRIVATE_KEY:-"./id_rsa_runner"}
    local trento_source_zip="${TRENTO_SERVER_CHART_VERSION}"
    local trento_chart_path=${TRENTO_CHART_PATH:-"/tmp/trento-${trento_source_zip}/helm-charts-${trento_source_zip}/charts/trento-server"}
    local trento_packages_url="https://github.com/${repo_owner}/helm-charts/archive/refs/tags"

    if [[ "$download_chart" == true ]]; then
        echo "Downloading trento-server chart..."
        pushd -- /tmp >/dev/null
        rm -rf trento-"${trento_source_zip}"
        rm -f ${trento_source_zip}.zip
        curl -f -sS -O -L "${trento_packages_url}/${trento_source_zip}.zip" >/dev/null
        unzip -o "${trento_source_zip}.zip" -d trento-"${trento_source_zip}" >/dev/null
        popd >/dev/null

        echo "Updating chart dependencies..."
        pushd -- "$trento_chart_path" >/dev/null
        helm dep update >/dev/null
        popd >/dev/null
    else
        trento_chart_path="$trento_chart_path --version ${TRENTO_SERVER_CHART_VERSION}"
    fi

    local args=(
        --set-file trento-runner.privateKey="${private_key}"
        --set trento-web.image.tag="${TRENTO_WEB_VERSION}"
        --set trento-web.image.repository="${web_image}"
        --set trento-runner.image.tag="${TRENTO_RUNNER_VERSION}"
        --set trento-runner.image.repository="${runner_image}"
        --set trento-web.adminUser.password="${ADMIN_PASSWORD}"
    )
    if [[ "$ENABLE_ALERTING" == "true" ]]; then
        args+=(
            --set trento-web.alerting.enabled=true
            --set trento-web.alerting.smtpServer="${SMTP_SERVER}"
            --set trento-web.alerting.smtpPort="${SMTP_PORT}"
            --set trento-web.alerting.smtpUser="${SMTP_USER}"
            --set trento-web.alerting.smtpPassword="${SMTP_PASSWORD}"
            --set trento-web.alerting.recipient="${ALERTING_RECIPIENT}"
        )
    fi
    if [[ "$ROLLING" == "true" ]]; then
        args+=(
            --set trento-web.image.pullPolicy=Always
            --set trento-runner.image.pullPolicy=Always
        )
    fi
    HELM_EXPERIMENTAL_OCI=1 helm upgrade --install trento-server $trento_chart_path "${args[@]}"
}

main() {
    cmdline "${ARGS[@]}"
    load_conf
    if [[ "$EXISTING_K8S" != "true" ]]; then
        echo "Installing trento-server on k3s..."
        check_requirements
        install_k3s
        install_helm
    fi
    update_helm_dependencies
    install_trento_server_chart
}
main
