obtain_horizon_sources() {
        info "Obtaining horizon sources"
        get_sources $1 horizon $2
}

verify_horizon_install() {
        echo 'fail'
}

# Stolen from devstack
function _horizon_config_set {
    local file=$1
    local section=$2
    local option=$3
    local value=$4

    if [ -z "$section" ]; then
        sed -e "/^$option/d" -i $local_settings
        echo -e "\n$option=$value" >> $file
    elif grep -q "^$section" $file; then
        local line=$(sed -ne "/^$section/,/^}/ { /^ *'$option':/ p; }" $file)
        if [ -n "$line" ]; then
            sed -i -e "/^$section/,/^}/ s/^\( *'$option'\) *:.*$/\1: $value,/" $file
        else
            sed -i -e "/^$section/a\    '$option': $value," $file
        fi
    else
        echo -e "\n\n$section = {\n    '$option': $value,\n}" >> $file
    fi
}


install_horizon() {
        local env_path=$1
        local branch=$2

        local admin_password=$(get_auth_info "admin_password")
        local horizon_password=$(get_auth_info "horizon_password")

        local installed=$(verify_horizon_install $env_path $admin_password)
        if [ "$installed" != "ok" ]; then
                obtain_horizon_sources $env_path $branch
                pip install $env_path/src/horizon
                HORIZON_DIR=$env_path/src/horizon
                HORIZON_SETTINGS=${HORIZON_SETTINGS:-$HORIZON_DIR/openstack_dashboard/local/local_settings.py.example}
                KEYSTONE_SERVICE_HOST=controller
                KEYSTONE_SERVICE_PROTOCOL=http
                KEYSTONE_SERVICE_PORT=5000


                mkdir $env_path/src/.blackhole

                venv_path="python-path=${env_path}/lib/python2.7/site-packages"
                sudo sh -c "cat ${TOP_DIR}/etc/apache-horizon.template | sed -e \"
                        s|%HORIZON_DIR%|$env_path/src/horizon|g;
                        s|%USER%|$STACK_USER|g;
                        s|%GROUP%|$STACK_USER|g;
                        s|%APACHE_NAME%|apache2|g;
                        s|%VIRTUALENV%|$venv_path|g;
                \" > /etc/apache2/vhosts.d/horizon.conf"
                local local_settings=$HORIZON_DIR/openstack_dashboard/local/local_settings.py
                cp $HORIZON_SETTINGS $local_settings
                _horizon_config_set $local_settings "" COMPRESS_OFFLINE True
                _horizon_config_set $local_settings "" OPENSTACK_KEYSTONE_DEFAULT_ROLE \"Member\"

                _horizon_config_set $local_settings "" OPENSTACK_HOST \"${KEYSTONE_SERVICE_HOST}\"
                _horizon_config_set $local_settings "" OPENSTACK_KEYSTONE_URL "\"${KEYSTONE_SERVICE_PROTOCOL}://${KEYSTONE_SERVICE_HOST}:${KEYSTONE_SERVICE_PORT}/v2.0\""
                (cd $HORIZON_DIR; ./run_tests.sh -N --compilemessages)
                # Setup alias for django-admin which could be different depending on distro
                local django_admin
                if type -p django-admin > /dev/null; then
                        django_admin=django-admin
                else
                        django_admin=django-admin.py
                fi
                cd $HORIZON_DIR

                DJANGO_SETTINGS_MODULE=openstack_dashboard.settings $django_admin collectstatic --noinput
                DJANGO_SETTINGS_MODULE=openstack_dashboard.settings $django_admin compress --force
        fi
}
