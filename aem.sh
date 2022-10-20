#!/bin/bash

#
#
# aem.sh functions
#

set_env() {
  export AEM_SDK_HOME=~/aem-sdk

  if [[ -z "${AEM_PROJECT_HOME}" ]]; then
    print_step "Please set the AEM_PROJECT_HOME environment variable." "" error
    exit 1
  fi

  AEM_SDK_ACTIVE=$(find $AEM_SDK_HOME/sdk -mindepth 1 -type d | sort -nr)
  export AEM_SDK_ACTIVE

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
  fi

  # get the local IP - it is used by Docker to reach the Publish instance
  AEM_HTTP_IP=$(ifconfig | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1')
  export AEM_HTTP_IP;

  export AEM_INSTANCE_HOME=$AEM_SDK_HOME/$AEM_TYPE
  export AEM_LOCALHOST=localhost:$AEM_HTTP_PORT
  export AEM_HTTP_LOCALHOST=http://$AEM_LOCALHOST
  export AEM_LOCALHOST_SSL=localhost:$AEM_HTTPS_PORT
  export AEM_HTTPS_LOCALHOST=https://$AEM_LOCALHOST_SSL

  # colors
  export NC='\033[0m'
  export RED='\033[0;31m'
  export GREEN='\033[0;32m'
  export YELLOW='\033[1;33m'
  export CYAN='\033[0;36m'
  export BLUE='\033[0;34m'
  export MAGENTA='\033[0;35m'
}

print_env() {
    echo -e "
      ${NC}AEM_TYPE .....            ${GREEN}${AEM_TYPE}
      ${NC}AEM_INSTANCE_HOME .....   ${GREEN}${AEM_INSTANCE_HOME}
      ${NC}AEM_SDK_HOME .....        ${GREEN}${AEM_SDK_HOME}
      ${NC}AEM_SDK_ACTIVE .....      ${GREEN}${AEM_SDK_ACTIVE}
      ${NC}AEM_PROJECT_HOME .....    ${GREEN}${AEM_PROJECT_HOME}
      ${NC}AEM_HTTP_IP .....         ${GREEN}${AEM_HTTP_IP}
      ${NC}AEM_HTTP_PORT .....       ${GREEN}${AEM_HTTP_PORT}
      ${NC}AEM_JVM_DEBUG_PORT .....  ${GREEN}${AEM_JVM_DEBUG_PORT}
      ${NC}AEM_HTTP_LOCALHOST .....  ${GREEN}${AEM_HTTP_LOCALHOST}
"

  # SSL, coming later
  # AEM_HTTPS_PORT .....      ${GREEN}${AEM_HTTPS_PORT}
  # AEM_HTTPS_LOCALHOST ..... ${GREEN}${AEM_HTTPS_LOCALHOST}
}

start_instance() {
  local the_crx_quickstart="$AEM_INSTANCE_HOME/crx-quickstart"

  if [ ! -d $the_crx_quickstart ]; then
    print_step "Skipping AEM ${AEM_TYPE} start" "${the_crx_quickstart} does not exist" error
    return 1
  fi

  print_step "Starting AEM ${AEM_TYPE}" "at ${the_crx_quickstart}"
  $the_crx_quickstart/bin/start

  ( tail -f -n0 $the_crx_quickstart/logs/stdout.log & ) | grep -q "Startup completed"
  echo -e "Ready${NC}\n"
}

stop_instance() {
  # Finds the AEM instance via lsof, stops it, and waits for the process to die peacefully
  the_aem_pid=$(ps -ef | grep java | grep "crx-quickstart" | grep "$AEM_TYPE" | awk '{ print $2 }')
  if [ -z "$the_aem_pid" ]; then
    print_step "Skipping AEM ${AEM_TYPE} stop" "no process ID found"
    return 1
  fi

  the_crx_quickstart=$(lsof -p "$the_aem_pid" | awk '{ print $9 }' | sort | grep -vE "(fonts|jvm|pipe|socket|tmp|x86|localhost|NAME|locale)" | grep -oE "^.*(publish|author)/crx-quickstart" | sort -u)
  if [ ! -d "$the_crx_quickstart" ]; then
    print_step "Skipping AEM ${AEM_TYPE}" "${the_crx_quickstart} does not exist" error
    return 1
  fi

  if [[ "$1" == "force" ]]; then
    print_step "Killing AEM ${AEM_TYPE}" "at ${the_crx_quickstart} with pid ${the_aem_pid}"
    kill -9 "$the_aem_pid"
  else
    print_step "Stopping AEM ${AEM_TYPE}" "at ${the_crx_quickstart} with pid ${the_aem_pid}"
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
    print_step "Cannot delete AEM ${AEM_TYPE}" "${AEM_INSTANCE_HOME} does not exist" error
    exit 1
  fi

  print_step "Destroy AEM ${AEM_TYPE}" "at ${AEM_INSTANCE_HOME}?"
  echo -e "${NC}"
  read -p "Are you sure? [y/n] " -n 1 -r

  if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo
    stop_instance "force"
    rm -rf $AEM_INSTANCE_HOME
    print_step "Deleted" "${AEM_INSTANCE_HOME}"
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

  print_step "Setting port" "${AEM_HTTP_PORT}"
  sed -i "s/CQ_PORT=4502/CQ_PORT=${AEM_HTTP_PORT}/g" $the_start_script

  # Set the run modes
  local the_run_modes="${AEM_TYPE},local"
  print_step "Setting runmodes" "${the_run_modes}"
  sed -i "s/CQ_RUNMODE='author'/CQ_RUNMODE='${the_run_modes}'/g" $the_start_script

  # Set the JVM debugger
  local the_debug_flags="-Xdebug -Xrunjdwp:transport=dt_socket,address=*:${AEM_JVM_DEBUG_PORT},suspend=n,server=y"
  print_step "Setting JVM debugger port" "${AEM_JVM_DEBUG_PORT}"
  sed -i "s/headless=true'/headless=true ${the_debug_flags}'/g" $the_start_script

  # Double the memory allocation
  print_step "Doubling memory" ""
  sed -i "s/-server -Xmx1024m -XX:MaxPermSize=256M/-server -Xmx2048m -XX:MaxPermSize=512M/g" $the_start_script

  # first boot
  bash $the_start_script
  block_until_bundles_active

  # TODO
  # Install replication agent
  #if [[ "$AEM_TYPE" == "author" ]]; then
    # configure_replication_agent
  # fi

  # TODO
  # setup_aem_ssl
}

print_aem_status() {
  the_bundles_status=$(curl -s -n "${AEM_HTTP_LOCALHOST}/system/console/bundles.json" | jq -r '.status' | sed "s/Bundle information: //g" )
  the_process=$(ps aux | grep java | grep $AEM_TYPE)

  the_sling_settings=$(curl -s -n "${AEM_HTTP_LOCALHOST}/system/console/status-slingsettings.txt" )
  the_system_properties=$(curl -s -n "${AEM_HTTP_LOCALHOST}/system/console/status-System%20Properties.txt" )
  the_sling_home=$(echo "${the_sling_settings}" | grep "Sling Home = " | sed "s/Sling Home = //g" )
  the_run_modes=$(echo "${the_system_properties}" | grep "sling.run.modes = " | sed "s/sling.run.modes = //g" )

  if [[ $the_bundles_status =~ all\ [0-9]{3}\ bundles\ active ]]; then
    echo -ne ${GREEN}
  elif [ ! -z "$the_bundles_status" ]; then
    echo -ne ${RED}
  else
    echo -ne ${RED}
  fi

  echo -e "AEM ${AEM_TYPE}${NC}"
  if [ -n "$the_process" ]; then
    echo -e "  ${CYAN}Home${NC}       $the_sling_home${NC}"
    echo -e "  ${CYAN}Bundles${NC}    ${the_bundles_status}${NC}"
    echo -e "  ${CYAN}Run modes${NC}  $the_run_modes${NC}"
    echo -e "  ${CYAN}Process${NC}    $the_process${NC}"
  fi
  echo ""
}

tail_log() {
  local the_log_filename=error.log
  if [ -n "$1" ]; then
    the_log_filename=$1
  fi

  if [[ ! $the_log_filename =~ .log$ ]]; then
    the_log_filename="${the_log_filename}.log"
  fi

  the_log_file="$AEM_INSTANCE_HOME/crx-quickstart/logs/$the_log_filename"

  if [ -f "$the_log_file" ]; then
    tail -n 0 -f "$the_log_file"
  else
    print_step "File does not exist:" "$the_log_file" error
    exit 1
  fi
}

print_step() {
  local the_header=$1
  local the_object=$2
  local the_type=$3

  local the_line
  if [[ "$the_type" == "error" ]]; then
    the_line="${RED}${the_header}${NC}"
  else
    the_line="${CYAN}${the_header}${NC}"
  fi

  if [ ! -z "$the_object" ]; then
    the_line="${the_line} ${BLUE}$the_object${NC}"
  fi
  echo -e "$the_line"
}

print_duration() {
  end=$(date +%s)
  time=$(($end-$BEGIN))
  ((h=${time}/3600))
  ((m=(${time}%3600)/60))
  ((s=${time}%60))
  printf "T %02d:%02d:%02d\n" $h $m $s
}

print_usage() {
  echo -e "${CYAN}aem${NC} is a helper script for managing local AEM instances. Usage:\n
  ${BLUE}create             ${NC}author|publish
  ${BLUE}destroy            ${NC}author|publish
  ${BLUE}install_content    ${NC}author|publish
  ${BLUE}install_project       ${NC}author|publish
  ${BLUE}status             ${NC}[author|publish]
  ${BLUE}start              ${NC}[author|publish]
  ${BLUE}stop               ${NC}[author|publish]
  ${BLUE}log                ${NC}author|publish [log_file]
  ${BLUE}dispatcher
  ${BLUE}help
${NC}"
}

toggle_workflow_components() {
  if [[ "$1" == "enable" || "$1" == "disable" ]]; then
    the_action=$1
    curl -n -s --data "action=$the_action" "$AEM_HTTP_LOCALHOST/system/console/components/com.adobe.granite.workflow.core.launcher.WorkflowLauncherImpl"
    curl -n -s --data "action=$the_action" "$AEM_HTTP_LOCALHOST/system/console/components/com.adobe.granite.workflow.core.launcher.WorkflowLauncherListener"
  fi
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

find_aem_bundle() {
  # Ex: `find_aem_bundle com.adobe.some.package`
  local the_search_string=$1
  find $AEM_INSTANCE_HOME/crx-quickstart -name '*.jar' -exec grep -Hls "${the_search_string}" {} \;
}

start_dispatcher() {
  local the_dispatcher_folder=$AEM_SDK_HOME/dispatcher
  local the_destination_script=$the_dispatcher_folder/dispatcher.sh

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
  the_dispatcher_sub_folder=$(find "$the_dispatcher_folder" -type d -mindepth 1 -maxdepth 1)

  # start using the AEM Project Dispatcher source files
  "$the_dispatcher_sub_folder"/bin/docker_run.sh "$AEM_PROJECT_HOME"/dispatcher/src "$AEM_HTTP_IP":$AEM_HTTP_PORT 8080
}

install_package() {
  local the_package_path=$1
  if [[ ! -f "${the_package_path}" ]]; then
      print_step "File at $the_package_path not found, cannot install package" "" error
      return 1
  fi
  local the_package_name
  the_package_name=$(basename $the_package_path)
  print_step "Installing package $the_package_name" "to $AEM_HTTP_LOCALHOST"
  curl -n -F file=@"${the_package_path}" -F name="${the_package_name}" -F force=true -F install=true "${AEM_HTTP_LOCALHOST}/crx/packmgr/service.jsp"
}

install_content() {
  toggle_workflow_components disable
  install_package "${AEM_SDK_CONTENT_PACKAGE}"
  install_package "${AEM_SDK_ASSETS_PACKAGE}"
  toggle_workflow_components enable
}

install_project() {
    local the_all_zip
    the_all_zip="$(find "$AEM_PROJECT_HOME"/all/target -maxdepth 1 -name '*.zip')"
    if [[ -f "${the_all_zip}" ]]; then
      install_package "${the_all_zip}"
    else
      print_step "Could not find the All zip file" "" error
      return 1
    fi
}


#
#
# aem.sh script
#

# Track time of certain commands
BEGIN=$(date +%s)
export BEGIN
show_duration=
aem_types=

# Basic input validation
if [[ "$1" == "" ]]; then
  print_usage
  exit
elif [[ "$2" == "" || "$2" == "both" || "$2" == "author publish" ]]; then
  aem_types="author publish"
elif [[ "$2" == "author" || "$2" == "publish" ]]; then
  aem_types=$2
fi

# These commands accept the arguments:
#   "" - to run the command against both, or
#   "author" / "publish" - to target a specific instance type
for the_type in $aem_types
do
  set_env "$the_type" # every command needs this
  case "$1" in
    start)
      start_instance
      show_duration=true
      ;;
    stop)
      stop_instance
      show_duration=true
      ;;
    destroy)
      destroy_instance
      show_duration=true
      ;;
    status)
      print_aem_status
      ;;
    print_env)
      print_env
      ;;
  esac
done

# These commands need arguments "author" or "publish" to target a specific instance type.
case "$1" in
  create)
    set_env $2
    print_env
    create_instance
    show_duration=true
    ;;
  install_content)
    set_env $2
    install_content
    show_duration=true
    ;;
  install_project)
    set_env $2
    install_project
    show_duration=true
    ;;
  dispatcher)
    set_env publish
    start_dispatcher
    ;;
  log)
    set_env $2
    tail_log $3
    ;;
  find_bundle)
    set_env author
    find_aem_bundle $3
    ;;
  help)
    print_usage
    ;;
esac

if [[ "$show_duration" == "true" ]]; then
  print_duration
fi
