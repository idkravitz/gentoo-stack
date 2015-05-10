obtain_neutron_sources() {
        info "Obtaining neutron sources"
        get_sources $1 neutron $2
}

verify_neutron_install() {
        echo 'ok'
}

install_neutron() {
        local env_path=$1
        local branch=$2

        local admin_password=$(get_auth_info "admin_password")
        local neutron_password=$(get_auth_info "neutron_password")
        local nova_password=$(get_auth_info "nova_password")

        local installed=$(verify_neutron_install $env_path $admin_password)
        if [ "$installed" != "ok" ]; then
                obtain_neutron_sources $env_path $branch
                pip install $env_path/src/neutron

                local neutrondb_pass=$(gen_password)
                store_auth_info 'neutrondb_pass' $neutrondb_pass
                $mysql <<EOF
DROP DATABASE IF EXISTS openstack_neutron;
CREATE DATABASE openstack_neutron;
GRANT ALL PRIVILEGES ON openstack_neutron.* TO 'neutron'@'localhost' IDENTIFIED BY '$neutrondb_pass';
FLUSH PRIVILEGES;
EOF
                . $env_path/bin/admin-openrc.sh
                [ -d /etc/neutron ] || sudo mkdir /etc/neutron
                sudo chown -R $STACK_USER:$STACK_USER /etc/neutron
                cp -rv $env_path/src/neutron/etc/* /etc/neutron

                keystone user-delete neutron
                keystone service-delete neutron

                keystone user-create --name=neutron --pass=$neutron_password
                keystone user-role-add --user=neutron --tenant=service --role=admin
                keystone service-create --name=neutron --type=network --description="OpenStack Networking Service"
                keystone endpoint-create \
                     --service-id $(keystone service-list | awk '/ network / {print $2}') \
                     --publicurl http://controller:9696 \
                     --adminurl http://controller:9696 \
                     --internalurl http://controller:9696

                cat ${TOP_DIR}/etc/neutron.conf | sed -e "
                        s|%OPENSTACK_PATH%|$env_path|g;
                        s|%NEUTRON_DBPASS%|$neutrondb_pass|g;
                        s|%NEUTRON_PASS%|$neutron_password|g;
                        s|%NOVA_PASS%|$nova_password|g;
                        " > /etc/neutron/neutron.conf
                cat ${TOP_DIR}/etc/ml2_conf.ini | sed -e "
                        s|%OPENSTACK_PATH%|$env_path|g;
                " > /etc/neutron/plugins/ml2/ml2_conf.ini
                cat ${TOP_DIR}/etc/l3_agent.ini | sed -e "
                        s|%OPENSTACK_PATH%|$env_path|g;
                " > /etc/neutron/l3_agent.ini
                cat ${TOP_DIR}/etc/dhcp_agent.ini | sed -e "
                        s|%OPENSTACK_PATH%|$env_path|g;
                " > /etc/neutron/dhcp_agent.ini
                cat ${TOP_DIR}/etc/metadata_agent.ini | sed -e "
                        s|%OPENSTACK_PATH%|$env_path|g;
                        s|%NEUTRON_PASS%|$neutron_password|g;
                        " > /etc/neutron/metadata_agent.ini

                neutron-db-manage --config-file /etc/neutron/neutron.conf \
                          --config-file /etc/neutron/plugins/ml2/ml2_conf.ini upgrade kilo

                sudo ln -s $env_path/bin/neutron-rootwrap /usr/local/bin/neutron-rootwrap
                sudo ln -s $env_path/bin/neutron-rootwrap-daemon /usr/local/bin/neutron-rootwrap-daemon
                sudo cp -v ${TOP_DIR}/init.d/openstack_neutron-dhcp-agent /etc/init.d/
                sudo cp -v ${TOP_DIR}/init.d/openstack_neutron-l3-agent /etc/init.d/
                sudo cp -v ${TOP_DIR}/init.d/openstack_neutron-metadata-agent /etc/init.d/
                sudo cp -v ${TOP_DIR}/init.d/openstack_neutron-openvswitch-agent /etc/init.d/
                sudo cp -v ${TOP_DIR}/init.d/openstack_neutron-server /etc/init.d/
                sudo sh -c "cat >/etc/conf.d/openstack_neutron-server <<EOF
OPENSTACK_PREFIX=$env_path
NEUTRON_USER=$STACK_USER
EOF
"
                sudo cp -v /etc/conf.d/openstack_neutron-server /etc/conf.d/openstack_neutron-openvswitch-agent
                sudo cp -v /etc/conf.d/openstack_neutron-server /etc/conf.d/openstack_neutron-metadata-agent
                sudo cp -v /etc/conf.d/openstack_neutron-server /etc/conf.d/openstack_neutron-l3-agent
                sudo cp -v /etc/conf.d/openstack_neutron-server /etc/conf.d/openstack_neutron-dhcp-agent

                sudo /sbin/service openstack_neutron-server restart
                sudo /sbin/service openstack_neutron-openvswitch-agent restart
                sudo /sbin/service openstack_neutron-metadata-agent restart
                sudo /sbin/service openstack_neutron-l3-agent restart
                sudo /sbin/service openstack_neutron-dhcp-agent restart

                sudo /sbin/service openstack_nova-api restart
                sudo /sbin/service openstack_nova-conductor restart
                sudo /sbin/service openstack_nova-cert restart
                sudo /sbin/service openstack_nova-scheduler restart
                sudo /sbin/service openstack_nova-novncproxy restart
                sudo /sbin/service openstack_nova-compute restart
        else
                info "Neutron is already installed"
        fi
}
