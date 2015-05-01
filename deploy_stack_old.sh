#!/bin/bash

# Script for deploying openstack since it drove me crazy

pushd "$(dirname $0)" >/dev/null
SRC_PATH="$(pwd -P)"
popd >/dev/null

. "$SRC_PATH/config"
. "$SRC_PATH/functions"


if [ -d "$SRC_PATH/.auth" ]; then
. "$OPENSTACK_PATH/bin/activate"

admin_token=$(<$SRC_PATH/.auth/admin_token)
keystonedb_pass=$(<$SRC_PATH/.auth/keystonedb)
glancedb_pass=$(<$SRC_PATH/.auth/glancedb)
glance_pass=$(<$SRC_PATH/.auth/glance)
novadb_pass=$(<$SRC_PATH/.auth/novadb)
nova_pass=$(<$SRC_PATH/.auth/nova)

service openstack_keystone start
sleep 5
keystone_check=$(keystone --os-username admin --os-tenant-name admin --os-password $ADMIN_PASS user-list 2>/dev/null | awk '/ admin / {print "ok"}')
service openstack_glance-api start
service openstack_glance-registry start
sleep 5
glance_check=$(glance --os-username admin --os-tenant-name admin --os-password $ADMIN_PASS image-list 2>/dev/null | awk '/ Container Format / {print "ok"}')
service openstack_nova start
sleep 5
nova_check=$(nova --os-username admin --os-tenant-name admin --os-password $ADMIN_PASS image-list 2>/dev/null | awk '/ ID / {print "ok" }')

fi

service openstack_nova stop
service openstack_glance-api stop
service openstack_glance-registry stop
service openstack_keystone stop

sleep 3

# Sometimes they aren't getting killed by unknown reason
killall keystone-all
killall glance-api
killall glance-registry
killall nova-all


inifill="$SRC_PATH/inifill.py"
BRANCH="stable/$RELEASE"
mkdir $SRC_PATH/.auth

[ -f "$OPENSTACK_PATH/bin/activate" ] || virtualenv -p python3 /opt/openstack
. "$OPENSTACK_PATH/bin/activate"

if [ -z "$keystone_check" ]; then 

mkdir -v "$OPENSTACK_PATH/log"
mkdir -v "$OPENSTACK_PATH/src"
mkdir -vp "$OPENSTACK_PATH/var/lib/glance"
mkdir -v "$OPENSTACK_PATH/var/lib/glance/images"
mkdir -v "$OPENSTACK_PATH/var/lib/glance/image-cache"
mkdir -vp "$OPENSTACK_PATH/var/lib/nova/state"
mkdir -vp "$OPENSTACK_PATH/var/lock"

pip install mysql

get_sources keystone
pip install $OPENSTACK_PATH/src/keystone



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
        | sed "s!%OPENSTACK_PATH%!$OPENSTACK_PATH!" \
        > /etc/glance/glance-api.conf

$inifill $SRC_PATH/etc/glance-registry.conf $OPENSTACK_PATH/src/glance/etc/glance-registry.conf \
        | sed "s/%GLANCE_PASS%/$glance_pass/" \
        | sed "s/%GLANCE_DBPASS%/$glancedb_pass/" \
        | sed "s!%OPENSTACK_PATH%!$OPENSTACK_PATH!" \
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

if [ -z "$nova_check" ]; then
get_sources nova
pip install $OPENSTACK_PATH/src/nova
pip install tox
pip install "git+https://github.com/stackforge/nova-docker#egg=novadocker"
cd $OPENSTACK_PATH/src/nova
tox -egenconfig

[ -d /etc/nova ] || mkdir /etc/nova
cp -rv $OPENSTACK_PATH/src/nova/etc/nova/* /etc/nova

novadb_pass=$(openssl rand -hex 10)
nova_pass=$(openssl rand -hex 10)

mysql <<EOF
DROP DATABASE IF EXISTS openstack_nova;
CREATE DATABASE openstack_nova;
GRANT ALL PRIVILEGES ON openstack_nova.* TO 'nova'@'localhost' IDENTIFIED BY '$novadb_pass';
FLUSH PRIVILEGES;
EOF

keystone user-create --name nova --pass $nova_pass
keystone user-role-add --user nova --tenant service --role admin
keystone service-create --name nova --type compute \
          --description "OpenStack Compute"
keystone endpoint-create \
          --service-id $(keystone service-list | awk '/ compute / {print $2}') \
          --publicurl http://controller:8774/v2/%\(tenant_id\)s \
          --internalurl http://controller:8774/v2/%\(tenant_id\)s \
          --adminurl http://controller:8774/v2/%\(tenant_id\)s \
          --region regionOne

$inifill $SRC_PATH/etc/nova.conf $OPENSTACK_PATH/src/nova/etc/nova/nova.conf.sample \
        | sed "s/%NOVA_PASS%/$nova_pass/" \
        | sed "s/%NOVA_DBPASS%/$novadb_pass/" \
        | sed "s!%OPENSTACK_PATH%!$OPENSTACK_PATH!" \
        > /etc/nova/nova.conf

nova-manage db sync

cp $SRC_PATH/init.d/openstack_nova /etc/init.d/openstack_nova
echo "OPENSTACK_PREFIX=$OPENSTACK_PATH" > /etc/conf.d/openstack_nova
echo $nova_pass > $SRC_PATH/.auth/nova
echo $novadb_pass > $SRC_PATH/.auth/novadb

cat >/etc/nova/rootwrap.d/docker.filters <<EOF
# nova-rootwrap command filters for setting up network in the docker driver
# This file should be owned by (and only-writeable by) the root user

[Filters]
# nova/virt/docker/driver.py: 'ln', '-sf', '/var/run/netns/.*'
ln: CommandFilter, /bin/ln, root
EOF
fi

get_sources horizon
#pip install $OPENSTACK_PATH/src/horizon
#cp "$OPENSTACK_PATH/src/horizon/openstack_dashboard/local/local_settings.py.example" "$OPENSTACK_PATH/src/horizon/openstack_dashboard/local/local_settings.py"
#cp -r $OPENSTACK_PATH/src/horizon/openstack_dashboard $OPENSTACK_PATH/lib/python2.7/site-packages/horizon/
