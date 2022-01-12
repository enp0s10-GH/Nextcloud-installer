#!/bin/bash
#
# This script installs & configures Nextcloud 
#
# INFORMATION: Go to line 204->214
#
 
nextcloud_version='23.0.0'                                                # Version of Nextcloud
db_pass="$(tr -dc 'A-Za-z0-9!&+-.?' </dev/urandom | head -c 22 ; echo)"   # Password for Database
nc_pass="$(tr -dc 'A-Za-z0-9!&+-.?' </dev/urandom | head -c 22 ; echo)"   # Password for Nextcloud User
nc_user='Admin'                                                           # Username of Nextcloud User
db_user='nextcloud'                                                       # Username of Database User
db_name='nextcloud'                                                       # Name of the Database
data_dir='/var/www/nextcloud/data'                                        # Directory where nextcloud Data is stored
system_user='www-data'                                                    # Username of the System-user
requirepass="$(echo "${db_pass}" | sha256sum | awk '{print $1}')"         # Key to access Redis
 
####################################
# Install Required Packages
# Arguments:
#   None
# Returns:
#   Null
####################################
install_prerequirements() {
  apt update -y
  apt install apache2 mariadb-server libapache2-mod-php7.4 -y
  apt install php7.4-gd php7.4-mysql php7.4-curl php7.4-mbstring php7.4-intl -y
  apt install php7.4-gmp php7.4-bcmath php-imagick php7.4-xml php7.4-zip -y
  apt install ssl-cert -y
  apt install redis-server php-redis -y
}
 
####################################
# Adds an entry into the Database
# Arguments:
#   3: array, attribute, value 
#   2: attribute, value
####################################
add_config_entry() {
  local cfg_arr="${1}"      # Array
  local cfg_attr="${2}"     # Attribute
  local cfg_value="${3}"    # Value of cfg_attr
  if [[ $# -eq 2 ]]; then
    sudo -u "${system_user}" php /var/www/nextcloud/occ config:system:set "${cfg_attr}" "${cfg_value}"
  elif [[ $# -eq 3 ]]; then 
    sudo -u "${system_user}" php /var/www/nextcloud/occ config:system:set "${cfg_arr}" "${cfg_attr}" "${cfg_value}"
  fi 
}
 
####################################
# Configure MySQL Database
# Returns:
#   Null
####################################
setup_mysql() {
  local sql_query="CREATE USER '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';
                   CREATE DATABASE IF NOT EXISTS ${db_name} CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
                   GRANT ALL PRIVILEGES ON ${db_name}.* TO '${db_user}'@'localhost';
                   FLUSH PRIVILEGES;"
 
  /etc/init.d/mysql start
  mysql -e "${sql_query}"
}
 
####################################
# Downoads required Nextcloud files
# Arguments:
#   None
####################################
download_nextcloud_dependencies() {
  mkdir temp_trash/
  wget -P temp_trash/ https://download.nextcloud.com/server/releases/nextcloud-"${nextcloud_version}".tar.bz2
  wget -P temp_trash/ https://download.nextcloud.com/server/releases/nextcloud-"${nextcloud_version}".tar.bz2.sha256
  wget -P temp_trash/ https://download.nextcloud.com/server/releases/nextcloud-"${nextcloud_version}".tar.bz2.asc
  wget -P temp_trash/ https://nextcloud.com/nextcloud.asc
}
 
####################################
# Checks the Checksum, Extract .tar, move dir to /var/www
# Arguments:
#   None
####################################
handle_nextcloud_dependencies() {
  sha256sum -c temp_trash/nextcloud-"${nextcloud_version}".tar.bz2.sha256 < temp_trash/nextcloud-"${nextcloud_version}".tar.bz2
  gpg --import temp_trash/nextcloud.asc
  gpg --verify temp_trash/nextcloud-"${nextcloud_version}".tar.bz2.asc temp_trash/nextcloud-"${nextcloud_version}".tar.bz2
  tar -xjf temp_trash/nextcloud-"${nextcloud_version}".tar.bz2 -C /var/www
  rm -rf temp_trash
}
 
####################################
# Configure Apache2, SSL and TLS
# Arguments:
#   None
# Returns:
#   Null
####################################
handle_ssl_tls_apache2() {
  make-ssl-cert generate-default-snakeoil --force-overwrite
  a2enmod rewrite
  a2enmod ssl
  cat <<EOF >/etc/apache2/sites-available/000-default.conf
<VirtualHost *:80>
    RewriteEngine On
    RewriteCond %{HTTPS} off
    RewriteRule (.*) https://%{HTTP_HOST}%{REQUEST_URI}
</VirtualHost>
EOF
 
  cat <<EOF >/etc/apache2/sites-available/default-ssl.conf
<IfModule mod_ssl.c>
	<VirtualHost _default_:443>
 
		ServerAdmin webmaster@localhost
		DocumentRoot /var/www/nextcloud
 
		ErrorLog ${APACHE_LOG_DIR}/error.log
		CustomLog ${APACHE_LOG_DIR}/access.log combined
		SSLEngine on
 
		SSLCertificateFile	/etc/ssl/certs/ssl-cert-snakeoil.pem
		SSLCertificateKeyFile /etc/ssl/private/ssl-cert-snakeoil.key
 
		<FilesMatch "\.(cgi|shtml|phtml|php)$">
				SSLOptions +StdEnvVars
		</FilesMatch>
		<Directory /usr/lib/cgi-bin>
				SSLOptions +StdEnvVars
		</Directory>
 
	</VirtualHost>
</IfModule>
EOF
  a2ensite default-ssl
  service apache2 reload
  chown -R www-data:www-data /var/www/nextcloud/
}
 
####################################
# Adds the Configuration to skip the Wizard
# Arguments:
#   None
####################################
apply_autoconfig() {
  sudo -u "${system_user}" php /var/www/nextcloud/occ maintenance:install \
    --admin-pass "${nc_pass}" \
    --admin-user "${nc_user}" \
    --database mysql \
    --database-name "${db_name}" \
    --database-pass "${db_pass}" \
    --database-user "${db_user}" \
    --data-dir "${data_dir}"
}
 
####################################
# Adds the IPv4 and IPv6 to the allowed Domains
# Arguments:
#   None
####################################
add_ips_to_trusted_domains() {
  local ipv4="$(ifconfig | grep inet | head -1 | awk '{print $2}')"
  local ipv6="$(hostname -I | grep -E -o '[0-9a-z:]+:[0-9a-z:]+' | head -n 1)"
  add_config_entry trusted_domains 1 --value="${ipv4}"
  add_config_entry trusted_domains 2 --value="${ipv6}"
}
 
####################################
# Connects Nextcloud with Redis
# Arguments:
#   None
####################################
configure_redist_cache() {
  echo "requirepass ${requirepass}" >> /etc/redis/redis.conf
  add_config_entry redis password --value="${requirepass}"
  add_config_entry memcache.local --value="\\OC\\Memcache\\Redis"
  add_config_entry memcache.distributed --value="\\OC\\Memcache\\Redis"
  add_config_entry memcache.locking --value="\\OC\\Memcache\\Redis"
  add_config_entry filelocking.enabled --value="true"
  add_config_entry redis port --value="0"
  add_config_entry redis host --value="localhost"
  service redis-server restart
}
 
####################################
# writes Data into an file and draws into Terminal
# Arguments:
#   None
# Outputs:
#   writes Data into an file
####################################
save_data() {
cat <<EOF >~/nextcloud_data
  !!!!!!!!!!!!!!!!! - SECRET - !!!!!!!!!!!!!!!!!
  Nextcloud Version: ${nextcloud_version}
  Database Name: ${db_name}
  Database User: ${db_user}
  Database Password (PLEASE CHANGE!): ${db_pass}
  Nextcloud User: ${nc_user}
  Nextcloud Password (PLEASE CHANGE!): ${nc_pass}
  !!!!!!!!!!!!!!!!! - SECRET - !!!!!!!!!!!!!!!!!
EOF
  cat ~/nextcloud_data
}
 
setup_nextcloud() {
### EXECUTION ###
install_prerequirements || return 1           # LINE 23-30
add_config_entry || return 1                  # LINE 38-47
setup_mysql || return 1                       # LINE 54-62
download_nextcloud_dependencies || return 1   # LINE 69-75
handle_nextcloud_dependencies || return 1     # LINE 82-88
handle_ssl_tls_apache2 || return 1            # LINE 97-136
apply_autoconfig || return 1                  # LINE 143-152
add_ips_to_trusted_domains || return 1        # LINE 159-164
configure_redist_cache || return 1            # LINE 172-182
save_data || return 1                         # LINE 190-202
}
 
setup_nextcloud

# THIS SCRIPT IS WRITTEN BY VINCENT ROCH - enforcer
