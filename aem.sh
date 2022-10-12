#!/bin/bash

#
#
# aem.sh functions
#

# set the environment variables for the current action
#   $1 - the aem instance type
set_env() {
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

  export AEM_HOME=/Users/matt/aem-sdk/$AEM_TYPE
  export AEM_LOCALHOST=localhost:$AEM_HTTP_PORT
  export AEM_HTTP_LOCALHOST=http://$AEM_LOCALHOST
  export AEM_LOCALHOST_SSL=localhost:$AEM_HTTPS_PORT
  export AEM_HTTPS_LOCALHOST=https://$AEM_LOCALHOST_SSL
  export AEM_SDK=$(ls -aht ~/aem-sdk | grep "aem-sdk-" | head -1)
}

print_env() {
    echo -e "
      ${NC}AEM_SDK .....             ${AEM_SDK}
      ${NC}AEM_TYPE .....            ${AEM_TYPE}
      ${NC}AEM_HOME .....            ${AEM_HOME}
      ${NC}AEM_HTTP_PORT .....       ${AEM_HTTP_PORT}
      ${NC}AEM_HTTPS_PORT .....      ${AEM_HTTPS_PORT}
      ${NC}AEM_JVM_DEBUG_PORT .....  ${AEM_JVM_DEBUG_PORT}
      ${NC}AEM_HTTP_LOCALHOST .....  ${AEM_HTTP_LOCALHOST}
      ${NC}AEM_HTTPS_LOCALHOST ..... ${AEM_HTTPS_LOCALHOST}
  "
}

start_instance() {
  local the_crx_quickstart="$AEM_HOME/crx-quickstart"

  if [ ! -d $the_crx_quickstart ]; then
    print_step "Skipping AEM ${AEM_TYPE}" "directory ${RED}${the_crx_quickstart}${NC} does not exist"
    return 1
  fi

  print_step "Starting" "AEM ${AEM_TYPE}${NC} at ${BLUE}${the_crx_quickstart}${NC}"
  $the_crx_quickstart/bin/start

  ( tail -f -n0 $the_crx_quickstart/logs/stdout.log & ) | grep -q "Startup completed"
  echo -e "Ready${NC}\n"
}

stop_instance() {
  
  # Finds the AEM instance via lsof, stops it, and waits for the process to die peacefully
  the_aem_pid=$(ps -ef | grep java | grep "crx-quickstart" | grep "$AEM_TYPE" | awk '{ print $2 }')
  if [ -z "$the_aem_pid" ]; then
    print_step "Skipping" "AEM ${AEM_TYPE}${NC}, no process ID found"
    return 1
  fi

  the_crx_quickstart=$(lsof -p $the_aem_pid | awk '{ print $9 }' | sort | grep -vE "(fonts|jvm|pipe|socket|tmp|x86|localhost|NAME|locale)" | grep -oE "^.*(publish|author)/crx-quickstart" | sort -u)
  if [ ! -d $the_crx_quickstart ]; then
    print_step "Skipping AEM ${AEM_TYPE}" "${RED}$the_crx_quickstart${NC} does not exist"
    return 1
  fi

  print_step "Stopping" "AEM ${AEM_TYPE}${NC} at ${BLUE}${the_crx_quickstart}${NC} with pid ${BLUE}${the_aem_pid}${NC}"
  local the_pid
  the_pid=$( ps -ef | grep $the_aem_pid | grep -v grep )
  $the_crx_quickstart/bin/stop

  while [[ $the_pid ]]; do
    sleep 1
    the_pid=$( ps -ef | grep $the_aem_pid | grep -v grep )
  done
}


destroy_instance() {
  local to_destroy="${AEM_HOME}"
  print_step "Destroy" "AEM ${AEM_TYPE}${NC} at ${BLUE}${to_destroy}${NC} ?"
  echo -e "${NC}"
  read -p "Are you sure? [y/n] " -n 1 -r

  if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo
    stop_instance $AEM_TYPE
    rm -rf $to_destroy
    echo -e "\nDone.${NC}\n"
  else
    echo
  fi
}


create_instance() {
  local the_crx_quickstart="$AEM_HOME/crx-quickstart"
  print_step "Creating" "AEM ${AEM_TYPE}${NC} at ${BLUE}${the_crx_quickstart}${NC}"
  mkdir -p $AEM_HOME
  the_quickstart_jar=$(ls ~/aem-sdk/$AEM_SDK | grep .jar)
  cd $AEM_HOME
  java -jar ~/aem-sdk/$AEM_SDK/$the_quickstart_jar -unpack

  # Set port
  local the_start_script=$AEM_HOME/crx-quickstart/bin/start

  print_step "Setting port to" "${AEM_HTTP_PORT}"
  sed -i "s/CQ_PORT=4502/CQ_PORT=${AEM_HTTP_PORT}/g" $the_start_script

  # Set runmodes"
  local the_runmodes="${AEM_TYPE},local"
  print_step "Setting runmodes to" "${the_runmodes}"
  sed -i "s/CQ_RUNMODE='author'/CQ_RUNMODE='${the_runmodes}'/g" $the_start_script

  # Set JVM debugger
  local the_debug_flags="-Xdebug -Xrunjdwp:transport=dt_socket,address=*:${AEM_JVM_DEBUG_PORT},suspend=n,server=y"
  print_step "Setting JVM debugger" "Port ${AEM_JVM_DEBUG_PORT}"
  sed -i "s/headless=true'/headless=true ${the_debug_flags}'/g" $the_start_script

  # Double the memory allocation
  print_step "Setting memory" "Port ${AEM_JVM_DEBUG_PORT}"
  sed -i "s/-server -Xmx1024m -XX:MaxPermSize=256M/-server -Xmx2048m -XX:MaxPermSize=512M/g" $the_start_script

  # first boot
  bash $the_start_script
  block_until_bundles_active

  # Install replication agent
  #if [[ "$AEM_TYPE" == "author" ]]; then
    # configure_replication_agent
  # fi

  # setup_aem_ssl
}

aem_status() {
  the_bundles_status=$(curl -s -n "${AEM_HTTP_LOCALHOST}/system/console/bundles.json" | jq -r '.status' | sed "s/Bundle information: //g" )
  the_process=$(ps aux | grep java | grep $AEM_TYPE)

  the_process_user=$(echo ${the_process} | awk '{print $1}')
  the_process_pid=$(echo ${the_process} | awk '{print $2}')
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
  if [ ! -z "$the_process" ]; then
    echo -e "  ${CYAN}Bundles${NC}    ${the_bundles_status}${NC}"
    echo -e "  ${CYAN}Run modes${NC}  $the_run_modes${NC}"
    echo -e "  ${CYAN}Home${NC}       $the_sling_home${NC}"
    echo -e "  ${CYAN}Process${NC}    $the_process${NC}"
  fi
  echo ""
}

tail_log() {
  local the_log_filename=error.log
  if [ ! -z "$1" ]; then
    the_log_filename=$1
  fi

  if [[ ! $the_log_filename =~ .log$ ]]; then
    the_log_filename="${the_log_filename}.log"
  fi

  the_log_file="$AEM_HOME/crx-quickstart/logs/$the_log_filename"

  if [ -f "$the_log_file" ]; then
    tail -n 0 -f $the_log_file
  else
    echo -e "${RED}The file at ${BLUE}$the_log_file${RED} does not exist. Check your arguments.${NC}"
    exit ${NC}1
  fi
}

print_step() {
  local the_message=$1
  local the_object=$2
  echo -e "${CYAN}$the_message $the_object${NC}"
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
  status         author|publish
  start          author|publish
  stop           author|publish
  log            author|publish [log_file]
"
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

restore_content() {
  toggle_workflow_components disable
  install_package $AEM_PACKAGE_ASSETS
  install_package $AEM_PACKAGE_CONTENT
  toggle_workflow_components enable
}

install_package() {  
  local the_package_path=$1
  local the_package_name=$(basename $the_package_path)
  curl -n -F file=@"${the_package_path}" -F name="${the_package_name}" -F force=true -F install=true "${AEM_HTTP_LOCALHOST}/crx/packmgr/service.jsp"
}

find_aem_bundle() {
  # Ex: `find_aem_bundle com.adobe.some.package`
  local the_search_string=$1
  find $AEM_HOME/crx-quickstart -name '*.jar' -exec grep -Hls "${the_search_string}" {} \;
}

start_dispatcher() {
  # kill any instance that may have been started previously
  # ps -ef | grep docker | ...?

  # find the script
  local the_source_script="${AEM_SDK}/$(ls $AEM_SDK | grep .sh)" # ex: ~/aem-sdk-2022.9.8722.20220912T101352Z-220800/aem-sdk-dispatcher-tools-2.0.117-unix.sh
  local the_folder=~/aem-sdk/dispatcher
  local the_script=$the_folder/dispatcher.sh
  
  # create dispatcher directory, empty it, and put the AEM SDK Dispatcher shell script in it
  rm -rf $the_folder
  mkdir -p $the_folder
  cp $the_source_script $the_script

  # make the script executable and execute it
  chmod a+x $the_script
  $the_script

  AEM_DISPATCHER_SRC=~/git/collibra-aem/src
  #$the_folder/bin/docker_run.sh $AEM_DISPATCHER_SRC 127.0.0.1:4503 8080   
}



#
#
# aem.sh script
#
export BEGIN=$(date +%s)
show_duration=
aem_types=
if [[ "$1" == "" && "$2" == "" ]]; then
  print_usage
  exit
elif [[ "$2" == "" || "$2" == "both" || "$2" == "author publish" ]]; then
  aem_types="author publish"
elif [[ "$2" == "author" || "$2" == "publish" ]]; then
  aem_types=$2
fi

# These actions support the arguments: "", "author", "publish"
for the_type in $aem_types
do
  set_env $the_type
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
      aem_status
      ;;
    print)
      print_env
      ;;
  esac
done

# These actions require the "author" or "publish" argument
case "$1" in
  help)
    print_usage
    ;;
  create)
    set_env $2
    print_env
    create_instance
    show_duration=true
    ;;
  restore_content)
    set_env $2
    restore_content
    show_duration=true
    ;;
  dispatcher)
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
esac

if [[ "$show_duration" == "true" ]]; then
  print_duration
fi
