#!/bin/bash

# Script for deploying openstack since it drove me crazy

pushd "$(dirname $0)" >/dev/null
SRC_PATH="$(pwd -P)"
popd >/dev/null

. "$SRC_PATH/config"
. "$SRC_PATH/functions"


if [ -d "$SRC_PATH/.auth" ]; then

admin_token=$(<$SRC_PATH/.auth/admin_token)
keystonedb_pass=$(<$SRC_PATH/.auth/keystonedb)
glancedb_pass=$(<$SRC_PATH/.auth/glancedb)
glance_pass=$(<$SRC_PATH/.auth/glance)

service openstack_keystone start
sleep 5
keystone_check=$(keystone --os-username admin --os-tenant-name admin --os-password $ADMIN_PASS user-list 2>/dev/null | awk '/ admin / {print "ok"}')
service openstack_glance-api start
service openstack_glance-registry start
sleep 5
glance_check=$(glance --os-username admin --os-tenant-name admin --os-password $ADMIN_PASS image-list 2>/dev/null | awk '/ Container Format / {print "ok"}')

fi

service openstack_keystone stop
service openstack_glance-api stop
service openstack_glance-registry stop

sleep 3

# Sometimes they aren't getting killed by unknown reason
killall keystone-all
killall glance-api
killall glance-registry



inifill="$SRC_PATH/inifill.py"
BRANCH="stable/$RELEASE"
mkdir $SRC_PATH/.auth

# STEP 1: deploy virtual env

[ -f "$OPENSTACK_PATH/bin/activate" ] || virtualenv -p python2.7 /opt/openstack
. "$OPENSTACK_PATH/bin/activate"

mkdir -v "$OPENSTACK_PATH/log"
mkdir -v "$OPENSTACK_PATH/src"
mkdir -vp "$OPENSTACK_PATH/var/lib/glance"
mkdir -v "$OPENSTACK_PATH/var/lib/glance/images"
mkdir -v "$OPENSTACK_PATH/var/lib/glance/image-cache"

pip install mysql

get_sources keystone
pip install $OPENSTACK_PATH/src/keystone


if [ -z "$keystone_check" ]; then 

admin_token=$(openssl rand -hex 10)
keystonedb_pass=$(openssl rand -hex 10)

echo $admin_token > $SRC_PATH/.auth/admin_token

mysql <<EOF
DROP DATABASE IF EXISTS openstack_keystone;
CREATE DATABASE openstack_keystone;
GRANT ALL PRIVILEGES ON openstack_keystone.* TO 'keystone'@'localhost' IDENTIFIED BY '$keystonedb_pass';
FLUSH PRIVILEGES;
EOF

echo $keystonedb_pass > $SRC_PATH/.auth/keystonedb

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
else

service openstack_keystone start
echo "Wait for keystone to start..."
sleep 7

fi

unset OS_SERVICE_TOKEN
unset OS_SERVICE_ENDPOINT

. $OPENSTACK_PATH/bin/admin-openrc.sh

get_sources glance
pip install $OPENSTACK_PATH/src/glance



if [ -z "$glance_check" ]; then

glancedb_pass=$(openssl rand -hex 10)
glance_pass=$(openssl rand -hex 10)

mysql <<EOF
DROP DATABASE IF EXISTS openstack_glance;
CREATE DATABASE openstack_glance;
GRANT ALL PRIVILEGES ON openstack_glance.* TO 'glance'@'localhost' IDENTIFIED BY '$glancedb_pass';
FLUSH PRIVILEGES;
EOF
echo $glancedb_pass > $SRC_PATH/.auth/glancedb

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

echo $glance_pass > $SRC_PATH/.auth/glance

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
pip install python-glanceclient
glance-manage db_sync

fi

service openstack_glance-api start
service openstack_glance-registry start
