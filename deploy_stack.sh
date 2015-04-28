#!/bin/bash

# Script for deploying openstack since it drove me crazy


service openstack_keystone stop
service openstack_glance-api stop
service openstack_glance-registry stop

pushd "$(dirname $0)" >/dev/null
SRC_PATH="$(pwd -P)"
inifill="$SRC_PATH/inifill.py"
popd >/dev/null

. $SRC_PATH/config

BRANCH="stable/$RELEASE"



# STEP 1: deploy virtual env

[ -f "$OPENSTACK_PATH/bin/activate" ] || virtualenv -p python2.7 /opt/openstack
. "$OPENSTACK_PATH/bin/activate"

mkdir "$OPENSTACK_PATH/log"
mkdir "$OPENSTACK_PATH/src"
mkdir -p "$OPENSTACK_PATH/var/lib/glance"
mkdir "$OPENSTACK_PATH/var/lib/glance/images"
mkdir "$OPENSTACK_PATH/var/lib/glance/image-cache"

pip install mysql

cd "$OPENSTACK_PATH/src"
[ -d keystone ] || git clone https://github.com/openstack/keystone.git
cd keystone
git checkout $BRANCH
pip install .

admin_token=$(openssl rand -hex 10)
keystonedb_pass=$(openssl rand -hex 10)

mysql <<EOF
DROP DATABASE IF EXISTS openstack_keystone;
CREATE DATABASE openstack_keystone;
GRANT ALL PRIVILEGES ON openstack_keystone.* TO 'keystone'@'localhost' IDENTIFIED BY '$keystonedb_pass';
FLUSH PRIVILEGES;
EOF

[ -d /etc/keystone ] || mkdir /etc/keystone
cp -rv $OPENSTACK_PATH/src/keystone/etc/* /etc/keystone

$inifill $SRC_PATH/etc/keystone.conf $OPENSTACK_PATH/src/keystone/etc/keystone.conf.sample \
        | sed "s/%KEYSTONE_PASS%/$keystonedb_pass/" \
        | sed "s/%ADMIN_TOKEN%/$admin_token/" \
        > /etc/keystone/keystone.conf

keystone-manage db_sync

cp $SRC_PATH/init.d/openstack_keystone /etc/init.d/openstack_keystone
echo "OPENSTACK_PREFIX=$OPENSTACK_PATH" > /etc/conf.d/openstack_keystone

service openstack_keystone start

echo "Wait for keystone to start..."
sleep 15

export OS_SERVICE_TOKEN=$admin_token
export OS_SERVICE_ENDPOINT=http://controller:35357/v2.0

# Setup admin user
keystone tenant-create --name admin --description "Admin Tenant"
keystone user-create --name admin --pass $ADMIN_PASS --email $ADMIN_EMAIL
keystone role-create --name admin
keystone user-role-add --user admin --tenant admin --role admin

keystone tenant-create --name service --description "Service Tenant"
keystone service-create --name keystone --type identity \
          --description "OpenStack Identity"
keystone endpoint-create \
          --service-id $(keystone service-list | awk '/ identity / {print $2}') \
          --publicurl http://controller:5000/v2.0 \
          --internalurl http://controller:5000/v2.0 \
          --adminurl http://controller:35357/v2.0 \
          --region regionOne
cat >$OPENSTACK_PATH/bin/admin-openrc.sh <<EOF
export OS_TENANT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=$ADMIN_PASS
export OS_AUTH_URL=http://controller:35357/v2.0
EOF

cd "$OPENSTACK_PATH/src"
[ -d glance ] || git clone https://github.com/openstack/glance.git
cd glance
git checkout $BRANCH
pip install .

glancedb_pass=$(openssl rand -hex 10)
glance_pass=$(openssl rand -hex 10)

mysql <<EOF
DROP DATABASE IF EXISTS openstack_glance;
CREATE DATABASE openstack_glance;
GRANT ALL PRIVILEGES ON openstack_glance.* TO 'glance'@'localhost' IDENTIFIED BY '$glancedb_pass';
FLUSH PRIVILEGES;
EOF

keystone user-create --name glance --pass $glance_pass
keystone user-role-add --user glance --tenant service --role admin
keystone service-create --name glance --type image \
          --description "OpenStack Image Service"
keystone endpoint-create \
          --service-id $(keystone service-list | awk '/ image / {print $2}') \
          --publicurl http://controller:9292 \
          --internalurl http://controller:9292 \
          --adminurl http://controller:9292 \
          --region regionOne

[ -d /etc/glance ] || mkdir /etc/glance
cp -rv $OPENSTACK_PATH/src/glance/etc/* /etc/glance

$inifill $SRC_PATH/etc/glance-api.conf $OPENSTACK_PATH/src/glance/etc/glance-api.conf \
        | sed "s/%GLANCE_PASS%/$glance_pass/" \
        | sed "s/%GLANCE_DBPASS%/$glancedb_pass/" \
        > /etc/glance/glance-api.conf

$inifill $SRC_PATH/etc/glance-registry.conf $OPENSTACK_PATH/src/glance/etc/glance-registry.conf \
        | sed "s/%GLANCE_PASS%/$glance_pass/" \
        | sed "s/%GLANCE_DBPASS%/$glancedb_pass/" \
        > /etc/glance/glance-registry.conf

cp $SRC_PATH/init.d/openstack_glance-api /etc/init.d/openstack_glance-api
cp $SRC_PATH/init.d/openstack_glance-registry /etc/init.d/openstack_glance-registry
echo "OPENSTACK_PREFIX=$OPENSTACK_PATH" > /etc/conf.d/openstack_glance-api
echo "OPENSTACK_PREFIX=$OPENSTACK_PATH" > /etc/conf.d/openstack_glance-registry

service openstack_glance-api start
service openstack_glance-registry start
