#!/bin/bash

set_env_vars() {
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

      # get the local IP - it is used by Docker to reach the Publish instance
      AEM_PUBLISH_IP=$(ifconfig | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1')
      if [[ -z "${AEM_PUBLISH_IP}" ]]; then
        print_step "Cannot compute AEM_PUBLISH_IP variable." "$AEM_PUBLISH_IP" error
        exit 1
      fi
      export AEM_PUBLISH_IP;
    fi

  export AEM_SDK_HOME=~/aem-sdk
  mkdir -p $AEM_SDK_HOME
  if [[ -z "${AEM_PROJECT_HOME}" ]]; then
    print_step "Please set the AEM_PROJECT_HOME environment variable." "" error
    exit 1
  fi

  # get the latest AEM SDK
  AEM_SDK_ACTIVE=$(find $AEM_SDK_HOME/sdk -mindepth 1 -type d | sort -nr)
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
    return
  fi

  local the_crx_quickstart="$AEM_INSTANCE_HOME/crx-quickstart"
  if [ ! -d $the_crx_quickstart ]; then
    print_step "Skipping AEM ${AEM_TYPE} start" "(${the_crx_quickstart} does not exist)" error
    return 1
  fi

  print_step "Starting AEM ${AEM_TYPE}" "at ${the_crx_quickstart}"
  $the_crx_quickstart/bin/start
  ( tail -f -n0 $the_crx_quickstart/logs/stdout.log & ) | grep -q "Startup completed"
  echo -e "Ready${NC}\n"
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
    print_step "Cannot delete AEM ${AEM_TYPE}" "${AEM_INSTANCE_HOME} does not exist" error
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
  $the_start_script
  block_until_bundles_active

  # TODO
  # Install replication agent
  #if [[ "$AEM_TYPE" == "author" ]]; then
    # configure_replication_agent
  # fi

  # TODO
  # setup_aem_ssl
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
    echo "AEM ${AEM_TYPE}"
    if [ -n "$the_process" ]; then
      print_justified "Home" "$the_sling_home"
      print_justified "Bundles" "$the_bundles_status"
      print_justified "Run modes" "$the_run_modes"
      print_justified "Process" "$the_process"
    fi
  fi

  echo
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

toggle_workflow_components() {
  if [[ "$1" == "enable" || "$1" == "disable" ]]; then
    the_action=$1
    curl -n -s --data "action=$the_action" "$AEM_HTTP_LOCALHOST/system/console/components/com.adobe.granite.workflow.core.launcher.WorkflowLauncherImpl"
    curl -n -s --data "action=$the_action" "$AEM_HTTP_LOCALHOST/system/console/components/com.adobe.granite.workflow.core.launcher.WorkflowLauncherListener"
    echo
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
  the_dispatcher_sub_folder=$(find "$the_dispatcher_folder" -type d -mindepth 1 -maxdepth 1)

  # start using the AEM Project Dispatcher source files
  DISP_LOG_LEVEL=Debug REWRITE_LOG_LEVEL=Debug "$the_dispatcher_sub_folder/bin/docker_run.sh" "$the_dispatcher_configs" "$AEM_PUBLISH_IP:$AEM_HTTP_PORT" $DOCKER_WEB_PORT &
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
  echo
}

install_content() {
  toggle_workflow_components disable
  # get the packages under $AEM_SDK_HOME/packages into an array
  files=()
  while IFS=  read -r -d $'\0'; do
      files+=("$REPLY")
  done < <(find "$AEM_SDK_HOME/packages" -name '*.zip' -print0)

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
    print_step "Could not find the All build artifact at ${AEM_PROJECT_HOME}" "" error
    return 1
  fi
}

hit_homepage() {
  if [[ -z "${AEM_PROJECT_HOME_PAGE}" ]]; then
    print_step "Please set the AEM_PROJECT_HOME_PAGE environment variable." "" error
    exit 1
  fi

  local the_url="$AEM_HTTP_LOCALHOST$AEM_PROJECT_HOME_PAGE"
  local curl_auth_opts=()
  if [[ "$AEM_TYPE" == "author" ]]; then
    the_url="$the_url?wcmmode=disabled"
    curl_auth_opts=( -n )
  fi

  # curl the homepage 5 times, print the response code, and sleep 3 seconds
  print_step "Hitting" "$the_url"
  for n in `seq 1 5`
  do
    the_http_code=$(curl "${curl_auth_opts[@]}" -s -o /dev/null -I -w "%{http_code}" "$the_url")
    print_justified "$n" "$the_http_code"
    sleep 3
  done
}

print_justified() {
  local the_command=$1
  local the_args=$2
  local the_description=$3
  printf "  ${MAGENTA}%-20s${NC}%-30s%-30s\n" "$the_command" "$the_args" "$the_description"
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
  printf "T %02d:%02d:%02d\n" $h $m $s
}

print_env_vars() {
  print_justified "AEM_TYPE" "$AEM_TYPE"
  print_justified "AEM_SDK_HOME" "$AEM_SDK_HOME"
  print_justified "AEM_SDK_ACTIVE" "$AEM_SDK_ACTIVE"
  print_justified "AEM_PROJECT_HOME" "$AEM_PROJECT_HOME"
  print_justified "AEM_INSTANCE_HOME" "$AEM_INSTANCE_HOME"

  if [[ "$AEM_TYPE" == "author" || "$AEM_TYPE" == "publish" ]]; then
    print_justified "AEM_JVM_DEBUG_PORT" "$AEM_JVM_DEBUG_PORT"

  elif [[ "$AEM_TYPE" == "web" ]]; then
    print_justified "DOCKER_WEB_PORT" "$DOCKER_WEB_PORT"
    print_justified "AEM_PUBLISH_IP" "AEM_PUBLISH_IP"
  fi
  echo
}

print_usage() {
  echo -e "${BLUE}aem.sh${NC} is a helper script for managing local AEMaaCS instances. Usage:\n"
  print_justified "create" "author|publish" "create a new AEM instance"
  print_justified "destroy" "author|publish" "stop and destroy an AEM instance"
  print_justified "install_content" "author|publish" "install the content packages under: $AEM_SDK_HOME/packages"
  print_justified "install_project" "author|publish" "install the 'all' artifact of the project: ${AEM_PROJECT_HOME}"
  print_justified "status" "[author|publish]" "print the status of one or more AEM instances"
  print_justified "start" "[author|publish|web]" "start an AEM instance, including web (Dispatcher)"
  print_justified "stop" "[author|publish]" "stop gracefully an AEM instance"
  print_justified "log" "author|publish [log_file]" "tail an AEM error.log file, or specify another one"
  print_justified "provision" "author|publish" "destroy, create, install code and content, and ping the homepage"
  print_justified "help" "" "show this screen"
}

no_web() {
  if [[ "${AEM_TYPE}" == "web" ]]; then
    print_step "'aem $1' not supported for" "$AEM_TYPE" error
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
  print_usage
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
    destroy)
      no_web $1
      destroy_instance
      show_duration=true
      ;;
    provision)
      no_web $1
      destroy_instance force
      create_instance
      install_code
      install_content
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
  log)
    no_web $1
    set_env_vars $2
    tail_log $3
    ;;
  hit_homepage)
    no_web $1
    set_env_vars $2
    hit_homepage
    ;;
  find_bundle)
    no_web $1
    set_env_vars author
    find_aem_bundle $3
    ;;
  help)
    print_usage
    ;;
esac

if [[ "$show_duration" == "true" ]]; then
  print_duration
fi
