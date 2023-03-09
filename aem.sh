#!/bin/bash

set_env_vars() {
  export AEM_SDK_HOME=~/aem-sdk
  mkdir -p $AEM_SDK_HOME
  if [[ -z "${AEM_PROJECT_HOME}" ]]; then
    print_step "Missing the environment variable:" "$AEM_PROJECT_HOME" error
    exit 1
  fi

  if [[ "$1" == "author" ]]; then
    export AEM_TYPE=author
    export AEM_HTTP_PORT=4502
    export AEM_HTTPS_PORT=5502
    export AEM_JVM_DEBUG_PORT=45020

  elif [[ "$1" == "publish" ]]; then
    export AEM_TYPE=publish
    export AEM_HTTP_PORT=4503
    export AEM_HTTPS_PORT=5503
    export AEM_JVM_DEBUG_PORT=45030

  elif [[ "$1" == "web" ]]; then
    export AEM_TYPE=web
    export AEM_HTTP_PORT=4503
    export DOCKER_WEB_PORT=8080
    export DOCKER_INTERNAL_HOST="host.docker.internal:$AEM_HTTP_PORT"
  fi

  # get the latest AEM SDK
  AEM_SDK_ACTIVE=$(find $AEM_SDK_HOME/sdk -mindepth 1 -type d | sort -nr | head -n 1 | tr -d '\n')
  export AEM_SDK_ACTIVE

  export AEM_INSTANCE_HOME=$AEM_SDK_HOME/$AEM_TYPE
  export AEM_LOCALHOST=localhost:$AEM_HTTP_PORT
  export AEM_HTTP_LOCALHOST=http://$AEM_LOCALHOST
  export AEM_LOCALHOST_SSL=localhost:$AEM_HTTPS_PORT
  export AEM_HTTPS_LOCALHOST=https://$AEM_LOCALHOST_SSL

  # colours!
  export CYAN='\033[0;36m'
  export GREEN='\033[0;32m'
  export BLUE='\033[0;34m'
  export RED='\033[0;31m'
  export MAGENTA='\033[0;35m'
  export NC='\033[0m' # no colour
}

start_instance() {
  if [[ "${AEM_TYPE}" == "web" ]]; then
    start_dispatcher
    sleep 2
    hit_homepage
    return
  fi

  local the_crx_quickstart="$AEM_INSTANCE_HOME/crx-quickstart"
  if [ ! -d $the_crx_quickstart ]; then
    print_step "Skipping AEM ${AEM_TYPE} start:" "(${the_crx_quickstart} does not exist)" error
    return 1
  fi

  print_step "Starting AEM ${AEM_TYPE}" "at ${the_crx_quickstart}"
  $the_crx_quickstart/bin/start
  ( tail -f -n0 $the_crx_quickstart/logs/stdout.log & ) | grep -q "Startup completed"
  echo -e "... ready${NC}"
}

stop_instance() {
  if [[ "${AEM_TYPE}" == "web" ]]; then
    the_container_id="$(docker container ls | grep adobe/aem | awk '{print $1}')"
    print_step "Stopping the Dispatcher Docker image" "$the_container_id"
    docker stop "$the_container_id"
    return
  fi

  # Finds the AEM instance via lsof, stops it, and waits for the process to die peacefully
  the_aem_pid=$(ps -ef | grep java | grep "crx-quickstart" | grep "$AEM_TYPE" | awk '{ print $2 }')
  if [ -z "$the_aem_pid" ]; then
    print_step "Skipping AEM ${AEM_TYPE} stop" "(no process ID found)"
    return 1
  fi

  the_crx_quickstart=$(lsof -p "$the_aem_pid" | awk '{ print $9 }' | sort | grep -vE "(fonts|jvm|pipe|socket|tmp|x86|localhost|NAME|locale)" | grep -oE "^.*(publish|author)/crx-quickstart" | sort -u)
  if [ ! -d "$the_crx_quickstart" ]; then
    print_step "Skipping AEM ${AEM_TYPE}" "(${the_crx_quickstart} does not exist)" error
    return 1
  fi

  if [[ "$1" == "force" ]]; then
    print_step "Killing AEM ${AEM_TYPE} with PID" "${the_aem_pid}"
    kill -9 "$the_aem_pid"
  else
    print_step "Stopping AEM ${AEM_TYPE} with PID" "${the_aem_pid}"
    local the_pid
    the_pid=$( ps -ef | grep "$the_aem_pid" | grep -v grep )
    "$the_crx_quickstart"/bin/stop

    while [[ $the_pid ]]; do
      sleep 1
      the_pid=$(ps -ef | grep "$the_aem_pid" | grep -v grep )
    done
  fi
}

destroy_instance() {
  if [ ! -d $AEM_INSTANCE_HOME ]; then
    print_step "Cannot delete AEM ${AEM_TYPE}:" "${AEM_INSTANCE_HOME} does not exist" error
    return 1
  fi

  if [[ "$1" != "force" ]]; then
    print_step "Destroy AEM ${AEM_TYPE} at" "${AEM_INSTANCE_HOME}?"
    read -p "Are you sure? [y/n] " -n 1 -r
    echo -e "${NC}"
  else
    REPLY="y"
  fi

  if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo
    stop_instance force
    rm -rf $AEM_INSTANCE_HOME
    print_step "Deleted" "${AEM_INSTANCE_HOME}!"
  else
    echo
  fi
}

create_instance() {
  local the_crx_quickstart="$AEM_INSTANCE_HOME/crx-quickstart"
  print_step "Creating AEM ${AEM_TYPE}" "at ${the_crx_quickstart}"
  mkdir -p $AEM_INSTANCE_HOME
  cd $AEM_INSTANCE_HOME || exit;

  the_quickstart_jar=$(find "$AEM_SDK_ACTIVE" -type f -name "*.jar")
  java -jar "$the_quickstart_jar" -unpack

  # Set port
  local the_start_script=$AEM_INSTANCE_HOME/crx-quickstart/bin/start

  print_justified "Setting port" "${AEM_HTTP_PORT}"
  sed -i "s/CQ_PORT=4502/CQ_PORT=${AEM_HTTP_PORT}/g" $the_start_script

  # Set the JVM debugger
  local the_debug_flags="-Xdebug -Xrunjdwp:transport=dt_socket,address=*:${AEM_JVM_DEBUG_PORT},suspend=n,server=y"
  print_justified "Setting debugger port" "${AEM_JVM_DEBUG_PORT}"
  sed -i "s/headless=true'/headless=true ${the_debug_flags}'/g" $the_start_script

  # Set the run modes
  local the_run_modes="${AEM_TYPE},local"
  print_justified "Setting runmodes" "${the_run_modes}"
  sed -i "s/CQ_RUNMODE='author'/CQ_RUNMODE='${the_run_modes}'/g" $the_start_script

  # Double the memory allocation
  local the_memory="-server -Xmx2048m -XX:MaxPermSize=512M"
  print_justified "Setting memory" "$the_memory"
  sed -i "s/-server -Xmx1024m -XX:MaxPermSize=256M/${the_memory}/g" $the_start_script

  # on first boot, wait for all bundles
  $the_start_script
  block_until_bundles_active

  configure_replication
  setup_instance_ssl
}

configure_replication() {
  if [[ "$AEM_TYPE" == "author" ]]; then
    print_step "Configuring the Replication Agent on" "Author"
    # get the encrypted password for admin and set in the replication agent config
    local the_encrypted_password
    the_encrypted_password=$(curl -s -n -F datum=admin "${AEM_HTTP_LOCALHOST}/system/console/crypto/.json" | jq -r '.protected' )
    the_http_code=$(curl -n -s -o /dev/null -w "%{http_code}" \
            -F "enabled=true" -F "userId=" \
            -F "transportUser=admin" -F "transportPassword=${the_encrypted_password}" \
            -F "transportUri=http://localhost:4503/bin/receive?sling:authRequestLogin=1" \
            "${AEM_HTTP_LOCALHOST}/etc/replication/agents.author/publish/jcr:content")
    print_justified "..." "$the_http_code"
  fi
}

setup_instance_ssl() {
  print_step "Setting up SSL in AEM" "${AEM_TYPE}"
  local the_crypto_dir=${AEM_INSTANCE_HOME}/.crypto_keys
  mkdir -p $the_crypto_dir

  # create the private key
  local the_pass_phrase="password"
  openssl genrsa -aes256 -passout pass:${the_pass_phrase} -out "$the_crypto_dir/localhostprivate.key" 4096

  # generate a Certificate Signing Request (CSR) using private key
  openssl rsa -passin pass:${the_pass_phrase} -in "$the_crypto_dir/localhostprivate.key" -out "$the_crypto_dir/localhostprivate.key"
  openssl req -sha256 -new -key "$the_crypto_dir/localhostprivate.key" -out "$the_crypto_dir/localhost.csr" -subj '/CN=localhost'

  # generate SSL certificate and sign it with the private key.
  # expires one year from now.
  openssl x509 -req -days 365 -in "$the_crypto_dir/localhost.csr" -signkey "$the_crypto_dir/localhostprivate.key" -out "$the_crypto_dir/localhost.crt"

  # convert the Private Key to DER format (the SSL wizard requires key to be in DER format)
  openssl pkcs8 -topk8 -inform PEM -outform DER -in "$the_crypto_dir/localhostprivate.key" -out "$the_crypto_dir/localhostprivate.der" -nocrypt

  # configure AEM via the SSL wizard
  the_http_code=$(curl -n -s -o /dev/null -w "%{http_code}" \
      -F "keystorePassword=${the_pass_phrase}" -F "keystorePasswordConfirm=${the_pass_phrase}" \
      -F "truststorePassword=${the_pass_phrase}" -F "truststorePasswordConfirm=${the_pass_phrase}" \
      -F "privatekeyFile=@$the_crypto_dir/localhostprivate.der" -F "certificateFile=@$the_crypto_dir/localhost.crt" \
      -F "httpsHostname=localhost" -F "httpsPort=${AEM_HTTPS_PORT}" \
      "${AEM_HTTP_LOCALHOST}/libs/granite/security/post/sslSetup.html")
  print_justified "Configuring SSL..." "$the_http_code"
  block_until_bundles_active

  # Once you have executed the command, verify that all the certificates made it to the keystore. Check the keystore from:
  # http://localhost:4502/libs/granite/security/content/userEditor.html/home/users/system/security/ssl-service
  # https://experienceleague.adobe.com/docs/experience-manager-65/administering/security/ssl-by-default.html
}

instance_status() {
  if [[ "$AEM_TYPE" == "web" ]]; then
    local the_docker_ls
    the_docker_ls="$(docker container ls | grep adobe/aem)"
    if [[ -z "${the_docker_ls}" ]]; then
      echo -ne "${RED}AEM ${AEM_TYPE}"
    else
      echo -ne "${GREEN}AEM ${AEM_TYPE}${NC}\n${the_docker_ls}"
    fi

  else
    the_bundles_status=$(curl -s -n "${AEM_HTTP_LOCALHOST}/system/console/bundles.json" | jq -r '.status' | sed "s/Bundle information: //g" )
    the_process=$(ps aux | grep java | grep $AEM_TYPE)

    the_sling_settings=$(curl -s -n "${AEM_HTTP_LOCALHOST}/system/console/status-slingsettings.txt" )
    the_sling_home=$(echo "${the_sling_settings}" | grep "Sling Home = " | sed "s/Sling Home = //g" )

    the_system_properties=$(curl -s -n "${AEM_HTTP_LOCALHOST}/system/console/status-System%20Properties.txt" )
    the_run_modes=$(echo "${the_system_properties}" | grep "sling.run.modes = " | awk '{print $3}')

    if [[ $the_bundles_status =~ all\ [0-9]{3}\ bundles\ active ]]; then
      echo -ne ${GREEN}
    elif [ ! -z "$the_bundles_status" ]; then
      echo -ne ${RED}
    else
      echo -ne ${RED}
    fi
    echo "AEM ${AEM_TYPE}"
    if [ -n "$the_process" ]; then
      print_justified "Home" "$the_sling_home"
      print_justified "Run modes" "$the_run_modes"
      print_justified "Bundles" "$the_bundles_status"
      print_justified "Process" "$the_process"
    fi
  fi

  echo
}

form_log_filename() {
  # determine the log file name
  local the_log_filename
  if [ -n "$1" ]; then
    the_log_filename=$1
  else
    if [[ "$AEM_TYPE" == "web" ]]; then
      # available logs:
      # - httpd_access.log
      # - httpd_error.log
      # - dispatcher.log
      # - healthcheck_access_log
      # - httpd_mod_security_audit.log -
      # httpd_mod_security_debug.log
      the_log_filename=httpd_error.log
    else
      # available logs:
      # - error.log
      # - access.log
      # - request.log
      # - queryrecorder.log
      # - stdout.log
      # - history.log
      the_log_filename=error.log
    fi
  fi

  # append extension if missing
  if [[ ! $the_log_filename =~ .log$ ]]; then
    the_log_filename="${the_log_filename}.log"
  fi

  echo $the_log_filename
}

tail_log() {
  the_log_file=$(form_log_filename $1)
  # tail the log
  if [[ "$AEM_TYPE" == "web" ]]; then # the log in Docker
    the_container_id="$(docker container ls | grep adobe/aem | awk '{print $1}')"
    the_log_file="/var/log/apache2/$the_log_filename"
    docker exec -it "$the_container_id" tail -f "$the_log_file"
  else # the local AEM log
    the_log_file="$AEM_INSTANCE_HOME/crx-quickstart/logs/$the_log_filename"
    if [ -f "$the_log_file" ]; then
      tail -n 0 -f "$the_log_file"
    else
      print_step "File does not exist:" "$the_log_file" error
      exit 1
    fi
  fi
}

list_log() {
  # list the log files for type
  if [[ "$AEM_TYPE" == "web" ]]; then # the log in Docker
    the_container_id="$(docker container ls | grep adobe/aem | awk '{print $1}')"
    docker exec -it "$the_container_id" ls -Slh "/var/log/apache2"
  else # the local AEM log
    ls -Slh "$AEM_INSTANCE_HOME/crx-quickstart/logs"
  fi
}

print_log() {
  the_log_filename=$(form_log_filename $1)
  # print the log path
  if [[ "$AEM_TYPE" == "web" ]]; then # the log in Docker
    echo "/var/log/apache2/$the_log_filename"
  else # the local AEM log
    echo "$AEM_INSTANCE_HOME/crx-quickstart/logs/$the_log_filename"
  fi

}

toggle_workflow_components() {
  if [[ "$1" == "enable" || "$1" == "disable" ]]; then
    local the_action=$1
    print_step "$(echo $the_action | sed 's/./\U&/')" "asset workflows"
    toggle_workflow_component "$the_action" "com.adobe.granite.workflow.core.launcher.WorkflowLauncherImpl"
    toggle_workflow_component "$the_action" "com.adobe.granite.workflow.core.launcher.WorkflowLauncherListener"
  fi
}

toggle_workflow_component() {
  local the_action=$1
  local the_osgi_component=$2
  the_http_code=$(curl -n -s -o /dev/null -w "%{http_code}" --data "action=$the_action" "$AEM_HTTP_LOCALHOST/system/console/components/$the_osgi_component")
  print_justified "$the_http_code" "$the_osgi_component"
}

block_until_bundles_active() {
  local bundles_status=
  local bundles_active=

  print_step "Waiting for bundles to start" "$AEM_HTTP_LOCALHOST"

  while [ -z "$bundles_active" ]; do
    bundles_status=$(curl -s -n "${AEM_HTTP_LOCALHOST}/system/console/bundles.json" | grep -o 'Bundle information: [^,]*\.')
    if [[ -z $bundles_status ]]; then
      sleep 2
    else
      bundles_active=$(echo $bundles_status | grep -oE 'all [0-9]{1,4} bundles active')
    fi
  done

  echo -e "${GREEN}$bundles_status${NC}"
}

find_in_bundles() {
  find "$AEM_INSTANCE_HOME/crx-quickstart/launchpad/felix" -name '*.jar' -exec grep -Hls "${1}" {} \;
}

start_dispatcher() {
  #Open Docker, only if is not running
  if (! docker stats --no-stream ); then
    # On Mac OS this would be the terminal command to launch Docker
    open "/Applications/Docker.app"
    # Wait until Docker daemon is running and has completed initialisation
    while (! docker stats --no-stream ); do
      # Docker takes a few seconds to initialize
      print_justified "Waiting for Docker to launch..."
      sleep 1
    done
  fi

  local the_dispatcher_configs="$AEM_PROJECT_HOME/dispatcher/src"
  local the_dispatcher_folder=$AEM_SDK_HOME/dispatcher
  local the_destination_script=$the_dispatcher_folder/dispatcher.sh

  print_step "Starting Dispatcher with config files at" "$the_dispatcher_configs"

  local the_source_script
  the_source_script="$(find "$AEM_SDK_ACTIVE" -type f -name '*.sh')"

  # clean and restart
  rm -rf "$the_dispatcher_folder"
  mkdir -p "$the_dispatcher_folder"
  cp "$the_source_script" "$the_destination_script"

  # make the script executable and execute it
  chmod a+x "$the_destination_script"
  cd "$the_dispatcher_folder" || exit
  $the_destination_script

  local the_dispatcher_sub_folder
  the_dispatcher_sub_folder=$(find "$the_dispatcher_folder" -name "dispatcher*" -type d -mindepth 1 -maxdepth 1)

  # start using the AEM Project Dispatcher source files
  # TODO Toggle "DISP_LOG_LEVEL=Debug REWRITE_LOG_LEVEL=Debug" with a flag?
  "$the_dispatcher_sub_folder/bin/docker_run.sh" "$the_dispatcher_configs" "$DOCKER_INTERNAL_HOST" "$DOCKER_WEB_PORT" > /dev/null 2>&1 &
}

validate_dispatcher() {
  local the_dispatcher_configs="$AEM_PROJECT_HOME/dispatcher/src"
  local the_dispatcher_folder=$AEM_SDK_HOME/dispatcher
  local the_dispatcher_sub_folder
  the_dispatcher_sub_folder=$(find "$the_dispatcher_folder" -name "dispatcher*" -type d -mindepth 1 -maxdepth 1)

  print_step "Validating Dispatcher config files at" "$the_dispatcher_configs"
  "$the_dispatcher_sub_folder/bin/validate.sh" "$the_dispatcher_configs"
}

install_package() {
  local the_package_path=$1
  if [[ ! -f "${the_package_path}" ]]; then
      print_step "File at $the_package_path not found, cannot install package:" "$the_package_path" error
      return 1
  fi
  local the_package_name
  the_package_name=$(basename $the_package_path)
  print_step "Installing package ${MAGENTA}$the_package_name${NC}" "to $AEM_HTTP_LOCALHOST"

  the_http_code=$(curl -n -s -o /dev/null -w "%{http_code}" -F file=@"${the_package_path}" -F name="${the_package_name}" -F force=true -F install=true "${AEM_HTTP_LOCALHOST}/crx/packmgr/service.jsp")
  print_justified "$the_http_code"
}

install_content() {
  toggle_workflow_components disable
  # get the packages under $AEM_SDK_HOME/packages into an array
  files=()
  while IFS=  read -r -d $'\0'; do
      files+=("$REPLY")
  done < <(find "$AEM_SDK_HOME/packages" -depth 1 -name '*.zip' -print0)

  # and install them
  for file in "${files[@]}"; do
    install_package "$file"
  done
  toggle_workflow_components enable
}

install_code() {
  local the_all_zip
  the_all_zip="$(find "$AEM_PROJECT_HOME"/all/target -maxdepth 1 -name '*.zip')"

  if [[ -f "${the_all_zip}" ]]; then
    install_package "${the_all_zip}"
  else
    print_step "Could not find the All build artifact at:" "${AEM_PROJECT_HOME}" error
    return 1
  fi
}

hit_homepage() {
  if [[ -z "${AEM_PROJECT_HOME_PAGE}" ]]; then
    print_step "Missing environment variable:" "AEM_PROJECT_HOME_PAGE" error
    exit 1
  fi

  local the_url
  local curl_auth_opts=()
  if [[ "${AEM_TYPE}" == "web" ]]; then
    the_url="http://localhost:8080/us/en"
  else
    the_url="$AEM_HTTP_LOCALHOST$AEM_PROJECT_HOME_PAGE"
    if [[ "$AEM_TYPE" == "author" ]]; then
      the_url="$the_url?wcmmode=disabled"
      curl_auth_opts=( -n )
    fi
  fi

  # hit the homepage 3 times
  # bing bang bung
  print_step "Hitting" "$the_url"
  for n in `seq 1 3`
  do
    the_http_code=$(curl "${curl_auth_opts[@]}" -s -o /dev/null -I -w "%{http_code}" "$the_url")
    print_justified "... $n ..." "$the_http_code"
    if [[ "$the_http_code" == "200" ]]; then
      break
    fi
    sleep 2
  done
}

print_justified() {
  local the_command=$1
  local the_args=$2
  local the_description=$3
  printf "  ${MAGENTA}%-25s${NC}%-35s${GREEN}%-50s${NC}\n" "$the_command" "$the_args" "$the_description"
}

print_step() {
  local the_header=$1
  local the_object=$2
  local the_type=$3

  local the_line
  if [[ "$the_type" == "error" ]]; then
    the_line="${RED}${the_header}${NC}"
  else
    the_line="${BLUE}${the_header}${NC}"
  fi

  if [ ! -z "$the_object" ]; then
    the_line="${the_line} ${CYAN}$the_object${NC}"
  fi
  echo -e "$the_line"
}

print_duration() {
  end=$(date +%s)
  time=$(($end-$BEGIN))
  ((h=${time}/3600))
  ((m=(${time}%3600)/60))
  ((s=${time}%60))
  the_time=$(printf "%02d:%02d:%02d\n" $h $m $s)
  print_justified "$the_time"
}

print_env_vars() {
  print_justified "---" "---"
  print_justified "AEM_TYPE" "$AEM_TYPE"
  print_justified "AEM_SDK_HOME" "$AEM_SDK_HOME"
  print_justified "AEM_SDK_ACTIVE" "$AEM_SDK_ACTIVE"
  print_justified "AEM_PROJECT_HOME" "$AEM_PROJECT_HOME"
  print_justified "AEM_INSTANCE_HOME" "$AEM_INSTANCE_HOME"

  if [[ "$AEM_TYPE" == "author" || "$AEM_TYPE" == "publish" ]]; then
    print_justified "AEM_HTTP_PORT" "$AEM_HTTP_PORT"
    print_justified "AEM_HTTPS_PORT" "$AEM_HTTPS_PORT"
    print_justified "AEM_HTTP_LOCALHOST" "$AEM_HTTP_LOCALHOST"
    print_justified "AEM_HTTPS_LOCALHOST" "$AEM_HTTPS_LOCALHOST"
    print_justified "AEM_JVM_DEBUG_PORT" "$AEM_JVM_DEBUG_PORT"

  elif [[ "$AEM_TYPE" == "web" ]]; then
    print_justified "DOCKER_WEB_PORT" "$DOCKER_WEB_PORT"
    print_justified "DOCKER_INTERNAL_HOST" "$DOCKER_INTERNAL_HOST"
  fi
  print_justified "---" "---"
}

print_help() {
  echo -e "${BLUE}aem.sh${NC} is a helper script for managing local AEMaaCS instances: Author, Publish, Web (Dispatcher). Usage:\n"
  print_justified "COMMAND" "ARG" "DESCRIPTION"
  print_justified "-------" "---" "-----------"
  print_justified "create" "author|publish" "Creates a new AEM instance at AEM_SDK_HOME."
  print_justified "destroy" "author|publish" "Stops and destroys an AEM instance by deleting its directory."
  print_justified "install_content" "author|publish" "Installs the content packages at AEM_SDK_HOME/packages."
  print_justified "install_project" "author|publish" "Installs the 'all' artifact of the project at AEM_PROJECT_HOME."
  print_justified "provision" "author|publish" "Destroys and creates a new AEM instance, installs code and content, and pings the homepage."
  print_justified "status" "[author|publish|web]" "Prints the status of an AEM or Web instances. Specify no argument to print all statuses."
  print_justified "start" "[author|publish|web]" "Starts an AEM or Web instance. Specify no argument to start all instances."
  print_justified "stop" "[author|publish|web]" "Stops gracefully an AEM or Web instance. Specify no argument to stop all instances."
  print_justified "log" "author|publish|web [log_file]" "Tails a log file from AEM or Web. Specify an exact filename to override the defaults: 'error.log' for AEM and 'httpd_error.log' for Web."
  print_justified "find" "search_string" "Grep bundle jars under crx-quickstart/launchpad/felix"
  print_justified "help" "" "Shows this screen!"
  print_justified ""
}

no_web() {
  if [[ "${AEM_TYPE}" == "web" ]]; then
    print_step "Command '$1' not supported for:" "$AEM_TYPE" error
    exit 1
  fi
}

no_aem() {
  if [[ "${AEM_TYPE}" != "web" ]]; then
    print_step "Command '$1' not supported for:" "$AEM_TYPE" error
    exit 1
  fi
}

# the script

# Track time of certain commands
BEGIN=$(date +%s)
export BEGIN
show_duration=
aem_types=

# Basic input validation
if [[ "$1" == "" ]]; then
  print_help
  exit 0
elif [[ "$2" == "author" || "$2" == "publish" || "$2" == "web" ]]; then
  aem_types=$2
elif [[ "$2" == "" ]]; then
  aem_types="author publish web"
fi


# Possible arguments:
#   - none (""), to run the command against all (where possible),
#   - or, by instance type: "author", "publish", or "web"
#
for the_type in $aem_types
do
  set_env_vars "$the_type" # every command needs this
  case "$1" in
    start)
      start_instance
      show_duration=true
      ;;
    stop)
      stop_instance
      show_duration=true
      ;;
    status)
      instance_status
      ;;
    destroy | delete)
      no_web $1
      destroy_instance
      show_duration=true
      ;;
    provision)
      no_web $1
      destroy_instance force
      create_instance
      install_content
      install_code
      hit_homepage
      show_duration=true
      ;;
    env_vars)
      print_env_vars
    ;;
  esac
done

# These commands need arguments "author" or "publish" to target a specific instance type.
case "$1" in
  create)
    no_web $1
    set_env_vars $2
    print_env_vars
    create_instance
    show_duration=true
    ;;
  install_content)
    no_web $1
    set_env_vars $2
    install_content
    show_duration=true
    ;;
  install_code)
    no_web $1
    set_env_vars $2
    install_code
    show_duration=true
    ;;
  list-log)
      set_env_vars $2
      list_log
      ;;
  print-log)
      set_env_vars $2
      print_log $3
      ;;
  log)
    set_env_vars $2
    tail_log $3
    ;;
  find)
    no_web $1
    set_env_vars author
    find_in_bundles $2
    ;;
  rep)
    no_web $1
    set_env_vars $1
    configure_replication
    ;;
  help)
    print_help
    ;;
  validate)
    no_aem $1
    set_env_vars $1
    validate_dispatcher
    ;;
esac

if [[ "$show_duration" == "true" ]]; then
  print_duration
fi
