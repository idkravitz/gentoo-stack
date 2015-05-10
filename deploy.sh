#!/bin/bash

umask 022

# keep track of sources dir
TOP_DIR=$(cd $(dirname "$0") && pwd)

# checking for unset variables
NOUNSET=${NOUNSET:-}
if [[ -n "$NOUNSET" ]]; then
    set -o nounset
fi

source "${TOP_DIR}/config"
source "${TOP_DIR}/functions"
source "${TOP_DIR}/components/keystone.sh"
source "${TOP_DIR}/components/glance.sh"
source "${TOP_DIR}/components/nova.sh"
source "${TOP_DIR}/components/neutron.sh"
source "${TOP_DIR}/components/horizon.sh"

# inifill.py command
inifill="${TOP_DIR}/inifill.py"
mysql="mysql --user=root --password=$MYSQL_PASS"

APACHE_NAME="apache2"

#useradd -M $STACK_USER
#usermod -L $STACK_USER

init_environment "$OPENSTACK_PATH"
pip install mysql

install_keystone "$OPENSTACK_PATH" "$BRANCH"
install_glance "$OPENSTACK_PATH" "$BRANCH"
install_nova "$OPENSTACK_PATH" "$BRANCH"
install_neutron "$OPENSTACK_PATH" "$BRANCH"
install_horizon "$OPENSTACK_PATH" "$BRANCH"
