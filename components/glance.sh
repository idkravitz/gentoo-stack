verify_glance_install() {
        local env_path=$1
        local admin_password=$2

        if [ -f "$env_path/bin/glance" ]; then
                if glance --os-username admin --os-tenant-name admin --os-password $admin_password \
                         --os-auth-url http://127.0.0.1:35357/v2.0 image-list >/dev/null 2>&1
                then
                        echo "ok"
                fi
        fi
}

obtain_glance_sources() {
        info "Obtaining glance sources"
        get_sources $1 glance $2
}

install_glance() {
        local env_path=$1
        local branch=$2

        local admin_password=$(get_auth_info "admin_password")
        local glance_password=$(get_auth_info "glance_password")

        local installed=$(verify_glance_install $env_path $admin_password)
        if [ "$installed" != "ok" ]; then
                obtain_glance_sources $env_path $branch
                pip install $env_path/src/glance

                local glancedb_pass=$(gen_password)
                store_auth_info 'glancedb_pass' $glancedb_pass

                mysql <<EOF
DROP DATABASE IF EXISTS openstack_glance;
CREATE DATABASE openstack_glance;
GRANT ALL PRIVILEGES ON openstack_glance.* TO 'glance'@'localhost' IDENTIFIED BY '$glancedb_pass';
FLUSH PRIVILEGES;
EOF

                . $env_path/bin/admin-openrc.sh

                keystone user-create --name glance --pass $glance_password
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
                rm -rf /etc/glance/*
                install -o $STACK_USER -m 644 $env_path/src/glance/etc/* /etc/glance
                $inifill ${TOP_DIR}/etc/glance-api.conf $env_path/src/glance/etc/glance-api.conf \
                        | sed "s/%GLANCE_PASS%/$glance_password/" \
                        | sed "s/%GLANCE_DBPASS%/$glancedb_pass/" \
                        | sed "s!%OPENSTACK_PATH%!$OPENSTACK_PATH!" \
                        > /etc/glance/glance-api.conf

                $inifill ${TOP_DIR}/etc/glance-registry.conf $env_path/src/glance/etc/glance-registry.conf \
                        | sed "s/%GLANCE_PASS%/$glance_password/" \
                        | sed "s/%GLANCE_DBPASS%/$glancedb_pass/" \
                        | sed "s!%OPENSTACK_PATH%!$OPENSTACK_PATH!" \
                        > /etc/glance/glance-registry.conf

                cp -v ${TOP_DIR}/init.d/openstack_glance-api /etc/init.d/openstack_glance-api
                cp -v ${TOP_DIR}/init.d/openstack_glance-registry /etc/init.d/openstack_glance-registry
                cat >/etc/conf.d/openstack_glance-api <<EOF
OPENSTACK_PREFIX=$OPENSTACK_PATH
GLANCE_USER=openstack
EOF
                cat >/etc/conf.d/openstack_glance-registry<<EOF
OPENSTACK_PREFIX=$OPENSTACK_PATH
GLANCE_USER=openstack
EOF
                chown -R ${STACK_USER}:${STACK_USER} /etc/glance
                pip install python-glanceclient
                glance-manage db_sync

                service openstack_glance-api restart
                service openstack_glance-registry restart

        fi
}
