#! /bin/bash
#Flagrantly stolen from rpedde (http://www.github.com/rpedde)

set -e
set -u
export DEBIAN_FRONTEND=noninteractive
source "$ROUSH_BASH_DIR/roush.sh"

if ! [[ -e /etc/debian_version ]] ; then
    echo "Attempted to run debian derivative script on non-debian distribution" 1>&2
    exit 1
fi

function get_sel() {
    # $1 - debconf selection to get

    local value=""
    if ( debconf-get-selections | grep -q ${1}); then
        value=$(debconf-get-selections | grep ${1} | awk '{ print $4 }')
        echo "Found existing debconf value for ${1}: ${value}" >&2
    fi

    echo ${value}
}

locale-gen en_US.UTF-8

apt-get install -y --force-yes debconf-utils pwgen wget lsb-release
cp /etc/resolv.conf /tmp/rc
apt-get remove --purge resolvconf -y --force-yes
cp /tmp/rc /etc/resolv.conf

PRIMARY_INTERFACE=$(ip route list match 0.0.0.0 | awk 'NR==1 {print $5}')
MY_IP=$(ip addr show dev ${PRIMARY_INTERFACE} | awk 'NR==3 {print $2}' | cut -d '/' -f1)

CHEF_URL=${CHEF_URL:-$(get_sel "chef/chef_server_url")}
CHEF_AMQP_PASSWORD=${CHEF_AMQP_PASSWORD:-$(get_sel "chef-solr/amqp_password")}
CHEF_WEBUI_PASSWORD=${CHEF_WEBUI_PASSWORD:-$(get_sel "chef-server-webui/admin_password")}
CHEF_UNIX_USER=${CHEF_UNIX_USER:-root}

# defaults if not set
CHEF_URL=${CHEF_URL:-http://${MY_IP}:4000}
CHEF_AMQP_PASSWORD=${CHEF_AMQP_PASSWORD:-$(pwgen -1)}
CHEF_WEBUI_PASSWORD=${CHEF_WEBUI_PASSWORD:-$(pwgen -1)}

if ( ! gpg --list-keys --secret-keyring /etc/apt/secring.gpg --trustdb-name /etc/apt/trustdb.gpg --keyring /etc/apt/trusted.gpg | grep 83EF826A ); then
    apt-key adv --keyserver keys.gnupg.net --recv-keys 83EF826A
fi

cat > /etc/apt/sources.list.d/opscode.list <<EOF
deb http://apt.opscode.com/ $(lsb_release -cs)-0.10 main
EOF

cat <<EOF | debconf-set-selections
chef chef/chef_server_url string ${CHEF_URL}
chef-solr chef-solr/amqp_password password ${CHEF_AMQP_PASSWORD}
chef-server-webui chef-server-webui/admin_password password ${CHEF_WEBUI_PASSWORD}
EOF

if ! dpkg -l chef-server | grep -v '^ii ' &>/dev/null; then
    apt-get update
    apt-get install -y --force-yes opscode-keyring
    sudo apt-get upgrade -y --force-yes
    set +e
    # something janky about the opscode packages
    sudo apt-get install -y --force-yes chef chef-server || /bin/true
    # sudo apt-get install -f -y
    sudo apt-get install -y --force-yes chef chef-server
    set -e
fi

HOMEDIR=$(getent passwd ${CHEF_UNIX_USER} | cut -d: -f6)
mkdir -p ${HOMEDIR}/.chef
cp /etc/chef/validation.pem /etc/chef/webui.pem ${HOMEDIR}/.chef
chown -R ${CHEF_UNIX_USER}: ${HOMEDIR}/.chef

/etc/init.d/couchdb stop || /bin/true
sleep 10
/etc/init.d/couchdb start || /bin/true
sleep 10

/etc/init.d/chef-server restart

sleep 10

if [[ ! -e ${HOMEDIR}/.chef/knife.rb ]]; then
cat <<EOF | knife configure -i
${HOMEDIR}/.chef/knife.rb
${CHEF_URL}
chefadmin
chef-webui
${HOMEDIR}/.chef/webui.pem
chef-validator
${HOMEDIR}/.chef/validation.pem

EOF
fi

return_fact "chef_server_client_name" "chefadmin"
return_fact "chef_server_client_pem" "$(cat /root/.chef/chefadmin.pem)"
return_fact "chef_server_uri" "$CHEF_URL"
return_fact "chef_server_pem" "$(cat /etc/chef/validation.pem)"
return_attr "chef_webui_password" "$CHEF_WEBUI_PASSWORD"