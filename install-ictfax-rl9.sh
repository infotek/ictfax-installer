#!/usr/bin/env sh
# ICTFax & ICTCore One-Line Installer https://www.ictfax.org/
# This exist for automated testing mostly because the documentation did not work
# ICT does not seem to be testing on 8, i think 8 requires a special mysql repo added
# Target OS: Enterprise Linux 8 & 9 (Rocky Linux, AlmaLinux, RHEL)
# 
# Version:   1.3.1
#
# Flexible Configuration Priority:
#   1. Pre-populated local file: ./.ictfax-credentials
#   2. Environment variables:    FAX_DOMAIN="fax.example.com" DB_PASS="custom" ./install-ictfax.sh
#   3. Automatic defaults:      Auto-generated passwords and hostname resolution
#
# Note:
#   Root execution caches state to /root/.ictfax-credentials for failure recovery.

set -eu

# Script Versioning
SCRIPT_VERSION="1.3.0"

# Color-coded log helper functions
info()  { printf "\033[34m[INFO]\033[0m %s\n" "$1"; }
warn()  { printf "\033[33m[WARN]\033[0m %s\n" "$1"; }
error() { printf "\033[31m[ERROR]\033[0m %s\n" "$1" >&2; }

main() {
  info "Starting ICTFax & ICTCore installer v${SCRIPT_VERSION}..."

  # =========================================================================
  # 1. Configuration Defaults & Local Credential Resolution
  # =========================================================================
  LOCAL_CRED_FILE="./.ictfax-credentials"
  ROOT_CRED_FILE="/root/.ictfax-credentials"

  # Source local credential file first if present in current execution path
  if [ -f "$LOCAL_CRED_FILE" ]; then
    info "Loading configuration from local state file ($LOCAL_CRED_FILE)..."
    . "$LOCAL_CRED_FILE"
  fi

  # Resolve Identity & Default Fallbacks (Inline Env Vars override defaults)
  FAX_DOMAIN="${FAX_DOMAIN:-$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "localhost")}"
  PRIMARY_IP="${PRIMARY_IP:-$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || echo "127.0.0.1")}"

  DB_NAME="${DB_NAME:-ictfax}"
  DB_USER="${DB_USER:-ictfaxuser}"
  DB_PASS="${DB_PASS:-$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)}"

  ADMIN_PASS="${ADMIN_PASS:-$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)}"
  USER_PASS="${USER_PASS:-$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)}"

  # =========================================================================
  # 2. Privilege Check & Sudo Resolution
  # =========================================================================
  SUDO=""
  if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
      SUDO="sudo"
    else
      error "This installer requires root privileges or 'sudo'. Please run as root."
      exit 1
    fi
  fi

  # =========================================================================
  # 3. Setup Temporary Working Directory & State-Aware Failure Trap
  # =========================================================================
  TMP_DIR="$(${SUDO} mktemp -d)"

  cleanup() {
    EXIT_CODE=$?
    if [ "$EXIT_CODE" -ne 0 ]; then
      printf "\n\033[41;37m                                                                \033[0m\n" >&2
      printf "\033[41;37m  [FATAL ERROR] Installation (v%s) aborted on line %-4s         \033[0m\n" "$SCRIPT_VERSION" "${1:-unknown}" >&2
      printf "\033[41;37m  Exit Code: %-5s                                              \033[0m\n" "$EXIT_CODE" >&2
      printf "\033[41;37m                                                                \033[0m\n" >&2
      printf "\033[41;37m  Active Configuration State:                                   \033[0m\n" >&2
      printf "\033[41;37m    Domain     : %-42s \033[0m\n" "${FAX_DOMAIN:-N/A}" >&2
      printf "\033[41;37m    DB Pass    : %-42s \033[0m\n" "${DB_PASS:-N/A}" >&2
      printf "\033[41;37m    Admin Pass : %-42s \033[0m\n" "${ADMIN_PASS:-N/A}" >&2
      printf "\033[41;37m    Demo Pass  : %-42s \033[0m\n" "${USER_PASS:-N/A}" >&2
      printf "\033[41;37m                                                                \033[0m\n\n" >&2
    fi
    info "Cleaning up temporary files..."
    ${SUDO} rm -rf "$TMP_DIR"
  }
  trap 'cleanup $LINENO' EXIT
  trap 'exit 130' INT TERM

  # Persist resolved active credentials to /root/.ictfax-credentials with strict permissions
  ${SUDO} touch "$ROOT_CRED_FILE"
  ${SUDO} chmod 600 "$ROOT_CRED_FILE"
  cat <<EOF | ${SUDO} tee "$ROOT_CRED_FILE" >/dev/null
FAX_DOMAIN="${FAX_DOMAIN}"
PRIMARY_IP="${PRIMARY_IP}"
DB_NAME="${DB_NAME}"
DB_USER="${DB_USER}"
DB_PASS="${DB_PASS}"
ADMIN_PASS="${ADMIN_PASS}"
USER_PASS="${USER_PASS}"
EOF

  # =========================================================================
  # 4. OS Version Detection
  # =========================================================================
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    EL_VER="${VERSION_ID%%.*}"
  else
    error "Cannot detect OS version. /etc/os-release is missing."
    exit 1
  fi

  if [ "$EL_VER" -ne 8 ] && [ "$EL_VER" -ne 9 ]; then
    warn "Unsupported distribution version detected (${EL_VER}). Proceeding with EL9 assumptions..."
    EL_VER=9
  fi

  info "Target System: Enterprise Linux ${EL_VER}"

  # =========================================================================
  # 5. Enable Repositories
  # =========================================================================
  info "Enabling EPEL, Remi, and ICTCore repositories for EL${EL_VER}..."
  ${SUDO} dnf install -y epel-release dnf-utils
  ${SUDO} dnf install -y "http://rpms.remirepo.net/enterprise/remi-release-${EL_VER}.rpm"
  
  if [ "$EL_VER" -eq 9 ]; then
    ${SUDO} dnf install -y https://service.ictinnovations.com/repo/9/ict-release-9-5.el9.noarch.rpm
    ${SUDO} dnf config-manager --enable crb
  elif [ "$EL_VER" -eq 8 ]; then
    ${SUDO} dnf install -y https://service.ictinnovations.com/repo/8/ict-release-8-5.el8.noarch.rpm
    ${SUDO} dnf config-manager --set-enabled powertools || ${SUDO} dnf config-manager --set-enabled PowerTools || true
  fi

  # =========================================================================
  # 6. Configure PHP & MariaDB Modules
  # =========================================================================
  info "Configuring PHP 8.3 and MariaDB modules..."
  ${SUDO} dnf module reset php -y
  ${SUDO} dnf module enable php:remi-8.3 -y

  if [ "$EL_VER" -eq 9 ]; then
    ${SUDO} dnf module enable mariadb:10.11 -y
  fi

  # =========================================================================
  # 7. Install PHP Mcrypt Extension (PECL)
  # =========================================================================
  info "Installing PHP Mcrypt extension..."
  ${SUDO} dnf install --enablerepo=epel -y php-devel php-pear libmcrypt libmcrypt-devel
  printf "\n" | ${SUDO} pecl install mcrypt || true

  if [ -f /usr/lib64/php/modules/mcrypt.so ]; then
    echo "extension=mcrypt.so" | ${SUDO} tee /etc/php.d/mcrypt.ini > /dev/null
  fi

  # =========================================================================
  # 8. Install Packages
  # =========================================================================
  info "Installing ICTCore, ICTFax, and dependent packages..."
  ${SUDO} dnf install -y php php-fpm php-gd php-mysqlnd mariadb-server mariadb libtiff-tools mod_ssl ictcore ictcore-email ictcore-freeswitch ictcore-fax ictcore-sendmail ictfax
  ${SUDO} systemctl enable --now mariadb

  # =========================================================================
  # 9. Configure Apache MPM Mode (prefork)
  # =========================================================================
  info "Configuring Apache MPM prefork mode..."
  if [ -f /etc/httpd/conf.modules.d/00-mpm.conf ]; then
    ${SUDO} sed -i 's/^\s*\(LoadModule\s\+mpm_event_module\s\+modules\/mod_mpm_event\.so\)/# \1/' /etc/httpd/conf.modules.d/00-mpm.conf
    ${SUDO} sed -i 's/^\s*#\s*\(LoadModule\s\+mpm_prefork_module\s\+modules\/mod_mpm_prefork\.so\)/\1/' /etc/httpd/conf.modules.d/00-mpm.conf
  fi

  # =========================================================================
  # 10. Initialize Database & Run SQL Schema Imports
  # =========================================================================
  info "Checking database state..."
  if ${SUDO} mysql -u root -e "USE ${DB_NAME};" >/dev/null 2>&1; then
    error "Database '${DB_NAME}' already exists!"
    error "Aborting installation to prevent accidental data loss or schema errors."
    error "If you intend to re-install, drop the database manually first:"
    error "  mysql -u root -e \"DROP DATABASE ${DB_NAME}; DROP USER '${DB_USER}'@'localhost';\""
    exit 1
  fi

  info "Initializing MariaDB database and user..."
  ${SUDO} mysql -u root <<EOF
CREATE DATABASE ${DB_NAME};
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
FLUSH PRIVILEGES;
EOF

  SQL_FILES="
    /usr/ictcore/db/database.sql
    /usr/ictcore/db/email.sql
    /usr/ictcore/db/fax.sql
    /usr/ictcore/db/data/role_user.sql
    /usr/ictcore/db/data/role_admin.sql
    /usr/ictcore/db/data/demo_users.sql
  "

  for sql_file in $SQL_FILES; do
    if [ -f "$sql_file" ]; then
      info "Importing database schema: $sql_file"
      ${SUDO} mysql -u root "$DB_NAME" < "$sql_file"
    fi
  done

  # =========================================================================
  # 11. Apply Credentials to Database Web Accounts
  # =========================================================================
  info "Applying generated passwords to database..."
  ${SUDO} mysql -u root "$DB_NAME" <<EOF
UPDATE usr SET passwd = MD5('${ADMIN_PASS}') WHERE username = 'admin';
UPDATE usr SET passwd = MD5('${USER_PASS}') WHERE username = 'user';
EOF

  # =========================================================================
  # 12. Update ICTCore Configuration File
  # =========================================================================
  info "Updating /etc/ictcore.conf..."
  if [ -f /etc/ictcore.conf ]; then
    ${SUDO} sed -i "s/^\s*user\s*=.*/user = ${DB_USER}/" /etc/ictcore.conf
    ${SUDO} sed -i "s/^\s*pass\s*=.*/pass = ${DB_PASS}/" /etc/ictcore.conf
    ${SUDO} sed -i "s/^\s*name\s*=.*/name = ${DB_NAME}/" /etc/ictcore.conf
  fi

  # =========================================================================
  # 13. Ensure Default SSL Certificates Exist via Installed mod_ssl Helper
  # =========================================================================
  if [ ! -f /etc/pki/tls/certs/localhost.crt ] || [ ! -f /etc/pki/tls/private/localhost.key ]; then
    info "Generating default SSL certificates via /usr/libexec/httpd-ssl-gencerts..."
    if [ -x /usr/libexec/httpd-ssl-gencerts ]; then
      ${SUDO} /usr/libexec/httpd-ssl-gencerts || true
    fi
  fi

  # =========================================================================
  # 14. Configure Apache SSL/TLS VirtualHost
  # =========================================================================
  info "Configuring Apache SSL/TLS VirtualHost for ${FAX_DOMAIN}..."

  cat <<EOF | ${SUDO} tee "/etc/httpd/conf.d/${FAX_DOMAIN}.conf" > /dev/null
<VirtualHost *:80>
    ServerName ${FAX_DOMAIN}
    ServerAlias ${PRIMARY_IP} 127.0.0.1 localhost
    Redirect permanent / https://${FAX_DOMAIN}/
</VirtualHost>

<VirtualHost *:443>
    ServerName ${FAX_DOMAIN}
    ServerAlias ${PRIMARY_IP} 127.0.0.1 localhost
    DocumentRoot /usr/ictfax

    SSLEngine on
    SSLCertificateFile /etc/pki/tls/certs/localhost.crt
    SSLCertificateKeyFile /etc/pki/tls/private/localhost.key

    SSLProtocol all -SSLv3 -TLSv1 -TLSv1.1
    SSLCipherSuite PROFILE=SYSTEM
    SSLHonorCipherOrder on

    <Directory /usr/ictfax>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted

        <IfModule mod_rewrite.c>
            RewriteEngine On
            RewriteBase /
            RewriteRule ^index\.html$ - [L]
            RewriteCond %{REQUEST_FILENAME} !-f
            RewriteCond %{REQUEST_FILENAME} !-d
            RewriteRule . /index.html [L]
        </IfModule>
    </Directory>

    Alias /api /usr/ictcore/wwwroot
    <Directory /usr/ictcore/wwwroot>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted

        <IfModule proxy_fcgi_module>
            SetEnv PHP_ADMIN_VALUE "open_basedir = /usr/ictcore/:/usr/bin:/bin:/tmp/:/etc/ictcore.conf"
        </IfModule>
    </Directory>

    ErrorLog logs/fax_ssl_error.log
    CustomLog logs/fax_ssl_access.log combined
</VirtualHost>
EOF

  ${SUDO} apachectl configtest

  # =========================================================================
  # 15. Sendmail Integration & Web Services Startup
  # =========================================================================
  info "Configuring Sendmail integrations..."
  echo "ictcore" | ${SUDO} tee -a /etc/mail/trusted-users > /dev/null
  echo "apache"  | ${SUDO} tee -a /etc/mail/trusted-users > /dev/null
  echo "${FAX_DOMAIN}" | ${SUDO} tee -a /etc/mail/local-host-names > /dev/null
  echo "@${FAX_DOMAIN} ictcore" | ${SUDO} tee -a /etc/mail/virtusertable > /dev/null

  if [ -f /etc/mail/make ]; then
    ${SUDO} /etc/mail/make
  fi

  info "Enabling and starting services..."
  ${SUDO} systemctl enable --now sendmail
  ${SUDO} systemctl enable --now php-fpm
  ${SUDO} systemctl enable --now httpd
  ${SUDO} systemctl reload httpd

  info "=================================================="
  info " Installation (v${SCRIPT_VERSION}) completed successfully!"
  info " Target System: Enterprise Linux ${EL_VER}"
  info " Web URL: https://${FAX_DOMAIN}/"
  info ""
  info " Generated MariaDB Credentials:"
  info "   DB Name    : ${DB_NAME}"
  info "   DB User    : ${DB_USER}"
  info "   DB Pass    : ${DB_PASS}"
  info ""
  info " Generated ICTFax Web Credentials:"
  info "   Admin User : admin@ictcore.org"
  info "   Admin Pass : ${ADMIN_PASS}"
  info ""
  info "   Demo User  : user@ictcore.org"
  info "   Demo Pass  : ${USER_PASS}"
  info ""
  info " State saved at: ${ROOT_CRED_FILE}"
  info " To issue a Let's Encrypt certificate later:"
  info "   sudo certbot --apache -d ${FAX_DOMAIN}"
  info "=================================================="
}

main "$@"
