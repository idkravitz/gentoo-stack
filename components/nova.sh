obtain_nova_sources() {
        info "Obtaining glance sources"
        get_sources $1 nova $2
}

verify_nova_install() {
        local env_path=$1
        local admin_password=$2

        if [ -f "$env_path/bin/glance" ]; then
                if nova --os-username admin --os-tenant-name admin --os-password $admin_password \
                         --os-auth-url http://127.0.0.1:35357/v2.0 list >/dev/null 2>&1
                then
                        echo "ok"
                fi
        fi
}

install_nova() {
        local env_path=$1
        local branch=$2

        local admin_password=$(get_auth_info "admin_password")
        local nova_password=$(get_auth_info "nova_password")
        local neutron_password=$(get_auth_info "neutron_password")

        local installed=$(verify_nova_install $env_path $admin_password)
        if [ "$installed" != "ok" ]; then
                obtain_nova_sources $env_path $branch
                pip install $env_path/src/nova
                pip install tox
                pip install "git+https://github.com/stackforge/nova-docker#egg=novadocker"
                cd $env_path/src/nova
                tox -egenconfig

                local novadb_pass=$(gen_password)
                store_auth_info 'novadb_pass' $novadb_pass
                $mysql <<EOF
DROP DATABASE IF EXISTS openstack_nova;
CREATE DATABASE openstack_nova;
GRANT ALL PRIVILEGES ON openstack_nova.* TO 'nova'@'localhost' IDENTIFIED BY '$novadb_pass';
FLUSH PRIVILEGES;
EOF
                . $env_path/bin/admin-openrc.sh
                [ -d /etc/nova-docker ] || sudo mkdir /etc/nova-docker
                sudo chown -R $STACK_USER:$STACK_USER /etc/nova-docker
                cp -rv $env_path/src/nova/etc/nova/* /etc/nova-docker

                # clean up after previous install
                keystone user-delete nova
                keystone service-delete nova

                keystone user-create --name nova --pass $nova_password
                keystone user-role-add --user nova --tenant service --role admin
                keystone service-create --name nova --type compute \
                          --description "OpenStack Compute"
                keystone endpoint-create \
                          --service-id $(keystone service-list | awk '/ compute / {print $2}') \
                          --publicurl http://controller:8774/v2/%\(tenant_id\)s \
                          --internalurl http://controller:8774/v2/%\(tenant_id\)s \
                          --adminurl http://controller:8774/v2/%\(tenant_id\)s \
                          --region regionOne

                #$inifill ${TOP_DIR}/etc/nova.conf $env_path/src/nova/etc/nova/nova.conf.sample \
                cat ${TOP_DIR}/etc/nova.conf | sed -e "
                        s|%NOVA_PASS%|$nova_password|g;
                        s|%NOVA_DBPASS%|$novadb_pass|g;
                        s|%NEUTRON_PASS%|$neutron_password|g;
                        s|%IP%|192.168.2.125|g;
                        s|%OPENSTACK_PATH%|$OPENSTACK_PATH|g;
                        " > /etc/nova-docker/nova.conf
                nova-manage --config-dir /etc/nova-docker db sync
                cat >/etc/nova-docker/rootwrap.d/docker.filters <<EOF
# nova-rootwrap command filters for setting up network in the docker driver
# This file should be owned by (and only-writeable by) the root user

[Filters]
# nova/virt/docker/driver.py: 'ln', '-sf', '/var/run/netns/.*'
ln: CommandFilter, /bin/ln, root
EOF
                cat ${TOP_DIR}/etc/rootwrap.conf | sed -e "
                        s|%CONFIG_DIR%|/etc/nova-docker|g;
                        s|%OPENSTACK_PATH%|$env_path|g;
                " > /etc/nova-docker/rootwrap.conf
                sudo cp -v ${TOP_DIR}/init.d/openstack_nova-api /etc/init.d
                sudo cp -v ${TOP_DIR}/init.d/openstack_nova-conductor /etc/init.d
                sudo cp -v ${TOP_DIR}/init.d/openstack_nova-cert /etc/init.d
                sudo cp -v ${TOP_DIR}/init.d/openstack_nova-scheduler /etc/init.d
                sudo cp -v ${TOP_DIR}/init.d/openstack_nova-novncproxy /etc/init.d
                sudo cp -v ${TOP_DIR}/init.d/openstack_nova-compute /etc/init.d
                sudo sh -c "cat >/etc/conf.d/openstack_nova-api <<EOF
OPENSTACK_PREFIX=$env_path
CONFIG_DIR=/etc/nova-docker
NOVA_USER=${STACK_USER}
EOF
"
                sudo cp -v /etc/conf.d/openstack_nova-api /etc/conf.d/openstack_nova-conductor
                sudo cp -v /etc/conf.d/openstack_nova-api /etc/conf.d/openstack_nova-cert
                sudo cp -v /etc/conf.d/openstack_nova-api /etc/conf.d/openstack_nova-scheduler
                sudo cp -v /etc/conf.d/openstack_nova-api /etc/conf.d/openstack_nova-novncproxy
                sudo cp -v /etc/conf.d/openstack_nova-api /etc/conf.d/openstack_nova-compute
                sudo ln -sv $env_path/bin/nova-rootwrap /usr/bin/nova-rootwrap

                sudo /sbin/service openstack_nova-api restart
                sudo /sbin/service openstack_nova-conductor restart
                sudo /sbin/service openstack_nova-cert restart
                sudo /sbin/service openstack_nova-scheduler restart
                sudo /sbin/service openstack_nova-novncproxy restart
                sudo /sbin/service openstack_nova-compute restart
        else
                info "Nova is already installed"
        fi
}
