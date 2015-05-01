#!/bin/bash

verify_keystone_install() {
        local env_path=$1
        local admin_password=$2

        if [ -f "$env_path/bin/keystone" ]; then
                if keystone --os-username admin --os-tenant-name admin --os-password $admin_password \
                         --os-auth-url http://127.0.0.1:35357/v2.0 user-list >/dev/null 2>&1
                then
                        echo "ok"
                fi
        fi
}

install_keystone() {
        local env_path=$1
        local branch=$2

        local admin_password=$(get_auth_info "admin_password")
        local admin_token=$(get_auth_info "admin_token")
        local installed=$(verify_keystone_install "$env_path" "$admin_password")

        if [ "$installed" != "ok" ]; then
                obtain_keystone_sources $env_path $branch
                pip install $env_path/src/keystone

                local keystonedb_pass=$(gen_password)
                store_auth_info "keystonedb_pass" $keystonedb_pass

                mysql <<EOF
DROP DATABASE IF EXISTS openstack_keystone;
CREATE DATABASE openstack_keystone;
GRANT ALL PRIVILEGES ON openstack_keystone.* TO 'keystone'@'localhost' IDENTIFIED BY '$keystonedb_pass';
FLUSH PRIVILEGES;
EOF
                [ -d /etc/keystone ] || mkdir /etc/keystone
                rm -rf /etc/keystone/*
                install -o $STACK_USER -m 644 $env_path/src/keystone/etc/* /etc/keystone

                $inifill ${TOP_DIR}/etc/keystone.conf $env_path/src/keystone/etc/keystone.conf.sample \
                        | sed "s/%KEYSTONE_DBPASS%/$keystonedb_pass/" \
                        | sed "s/%ADMIN_TOKEN%/$admin_token/" \
                        > /etc/keystone/keystone.conf
                local venv_path="python-path=${env_path}/lib/python2.7/site-packages"
                local KEYSTONE_DIR=$env_path/lib/python2.7/site-packages/keystone
                local KEYSTONE_WSGI_DIR=$env_path/var/www/keystone
                cp $env_path/src/keystone/httpd/keystone.py $KEYSTONE_WSGI_DIR/main
                cp $env_path/src/keystone/httpd/keystone.py $KEYSTONE_WSGI_DIR/admin
                cat ${TOP_DIR}/etc/apache-keystone.template \
                        | sed -e "
                                s|%ADMINPORT%|35357|g;
                                s|%PUBLICPORT%|5000|g;
                                s|%APACHE_NAME%|$APACHE_NAME|g;
                                s|%PUBLICWSGI%|$KEYSTONE_WSGI_DIR/main|g;
                                s|%PUBLICWSGI_DIR%|$KEYSTONE_WSGI_DIR|g;
                                s|%ADMINWSGI%|$KEYSTONE_WSGI_DIR/admin|g;
                                s|%ADMINWSGI_DIR%|$KEYSTONE_WSGI_DIR|g;
                                s|%USER%|$STACK_USER|g;
                                s|%VIRTUALENV%|$venv_path|g;
                                " > /etc/apache2/vhosts.d/keystone.conf
                chown -R ${STACK_USER}:${STACK_USER} /etc/keystone
                keystone-manage db_sync
                service apache2 restart
                export OS_SERVICE_TOKEN=$admin_token
                export OS_SERVICE_ENDPOINT=http://controller:35357/v2.0
                keystone tenant-create --name admin --description "Admin Tenant"
                keystone user-create --name admin --pass $admin_password --email $ADMIN_EMAIL
                keystone role-create --name admin
                keystone user-role-add --user admin --tenant admin --role admin
                cat >$env_path/bin/admin-openrc.sh <<EOF
export OS_TENANT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=$admin_password
export OS_AUTH_URL=http://controller:35357/v2.0
EOF

                keystone tenant-create --name service --description "Service Tenant"
                keystone service-create --name keystone --type identity \
                          --description "OpenStack Identity"
                keystone endpoint-create \
                          --service-id $(keystone service-list | awk '/ identity / {print $2}') \
                          --publicurl http://controller:5000/v2.0 \
                          --internalurl http://controller:5000/v2.0 \
                          --adminurl http://controller:35357/v2.0 \
                          --region regionOne
                unset OS_SERVICE_TOKEN
                unset OS_SERVICE_ENDPOINT

                . $env_path/bin/admin-openrc.sh

                local installed=$(verify_keystone_install "$env_path" "$admin_password")
                echo $installed
        fi
}


obtain_keystone_sources() {
        info "Obtaining keystone sources"
        get_sources $1 keystone $2
}
