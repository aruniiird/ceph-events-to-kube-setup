#!/bin/bash

DIR_0="$(cd $(dirname $0) && pwd)"
ENV_F="$DIR_0/minikube.env"
# the below order of files should not be changed
NEEDED_FILES=(common.yaml operator.yaml cluster.yaml toolbox.yaml pool.yaml filesystem.yaml)
MINIKUBE_DATA_DIR="/data/rook"
STORAGE_BASE_DIR="$PWD/libvirt"
unset TOBE_CLEANED

function needed_binaries() {
  local binary_list=(base64 minikube qemu-img virsh kubectl scp wget awk)
  local not_found=""
  for eachB in ${binary_list[@]};do
    if ! which $eachB 2>/dev/null 1>&2;then
      [ -z "$not_found" ] && echo -e "\nUnable to find"
      echo -e "$eachB"
      not_found="NotFound"
    fi
  done
  [ -n "$not_found" ] && return 1
  return 0
}

function start_minikube() {
  echo
  minikube config view
  echo
  if minikube status $PROFILE_NAME_WITH_P >/dev/null;then
    echo -e "\nStorage-Event-Management minikube cluster is running..."
  else
    minikube start $PROFILE_NAME_WITH_P
  fi
  return $?
}

function create_virtual_disks() {
  local nDisks=$1
  # as index will start from 1, 'a' will never be used
  local appendAlpha=(a b c d e f g)
  [ -z "${nDisks}" ] && nDisks=3
  local diskLocation="$STORAGE_BASE_DIR/images"
  [ ! -d "${diskLocation}" ] && mkdir -p "${diskLocation}"
  local profName=$PROFILE_NAME && [ -z "$profName" ] && profName="minikube"
  for (( i=1; i<=${nDisks}; i++ ));do
    local disk="${diskLocation}/osd$i.qcow2"
    [ ! -f ${disk} ] && qemu-img create -f qcow2 ${disk} 1T
    echo "$BASE64_SUDO_PASS" |base64 --decode |sudo -S virsh attach-disk $profName ${disk} vd${appendAlpha[i]} --driver qemu --subdriver qcow2 --targetbus virtio --persistent
  done
  minikube $PROFILE_NAME_WITH_P ssh "echo 'echo 1 >/sys/bus/pci/rescan' |su -"
}

function edit_yaml_files() {
  local yamlDir="$1"
  [ -z "${yamlDir}" ] && yamlDir="."
  # remove any '/'s at the end
  yamlDir="$(echo $yamlDir |sed -n 's@/*$@@gp')"
  local eachF=""
  for eachF in ${NEEDED_FILES[@]};do
    [ ! -f "${yamlDir}/${eachF}" ] && echo "Unable to find : ${yamlDir}/${eachF}" && return 1
  done
  if [ -z "$(sed -n '/^[[:space:]]*-[[:space:]]\+events/ p' ${yamlDir}/common.yaml)" ];then
    sed -i '/rook-ceph-mgr-cluster-rules/,/^---/ {
    /resources:/ a\  - events 
    }' ${yamlDir}/common.yaml
  fi
  if [ "$(sed -n '/rook-ceph-mgr-cluster-rules/,/^---/ p' ${yamlDir}/common.yaml |sed -n '/verbs:/,/- get/ p' |sed -n '/- create/,/- patch/ p' |sed -n 's/^\s*\(- patch\).*/\1/gp')" != "- patch" ];then
    sed -i '/rook-ceph-mgr-cluster-rules/,/^---/ {
    /verbs:/ a\
  - create\
  - patch\
  - get       
    }' ${yamlDir}/common.yaml
  fi
  sed -i 's@\(allowMultiplePerNode\).*@\1: true@g' ${yamlDir}/cluster.yaml
  if [ "$(sed -n '/dashboard:/,/^\s*#/ p' ${yamlDir}/cluster.yaml |sed -n 's/.*\(port\):.*/\1/gp')" != "port" ];then
    sed -i '\@^[[:space:]]*dashboard:@ a\
    port: 8443\
    ssl: true' ${yamlDir}/cluster.yaml
  fi
  sed -i 's@\(^\s*dataDirHostPath\).*@\1: '$MINIKUBE_DATA_DIR'@g' ${yamlDir}/cluster.yaml
}

function setup_rook() {
  [ -z "$ROOK_GITHUB_HOME" ] && ROOK_GITHUB_HOME="$PWD/rook"
  [ ! -d "$ROOK_GITHUB_HOME" ] && git clone https://github.com/rook/rook.git rook
  local cephExampleDir="$ROOK_GITHUB_HOME/cluster/examples/kubernetes/ceph"
  [ ! -f "${cephExampleDir}/common.yaml" ] && echo "Not a proper rook github clone ($ROOK_GITHUB_HOME)" && return 1
  local eachF=""
  local yamlDir="yamlFiles"
  [ ! -d "${yamlDir}" ] && mkdir "${yamlDir}"
  for eachF in ${NEEDED_FILES[@]};do
    [ ! -f ${yamlDir}/${eachF} ] && cp ${cephExampleDir}/${eachF} ${yamlDir}
  done
  edit_yaml_files ${yamlDir}
  for eachF in ${NEEDED_FILES[@]};do
    echo "Checking ${eachF}..."
    kubectl describe -f ${yamlDir}/${eachF} 1>/dev/null 2>&1 || { kubectl create -f ${yamlDir}/${eachF} && sleep 10s; }
  done
}

function get_pod_with_state() {
  local podSearchLine="$1" && [ -z "$podSearchLine" ] && echo "Sorry, was expecting atleast a pod name" >&2 && return 1
  local expectedState="$2" && [ -z "$expectedState" ] && expectedState="Running"
  local iterateTill="$3" && [ -z "$iterateTill" ] && iterateTill=20
  local foundPod=""
  local i=0
  while [ -z "${foundPod}" ] && [ $i -lt $iterateTill ];do
    local podLine="$(kubectl get pods -n rook-ceph |grep "${podSearchLine}")"
    if [ -n "${podLine}" ];then
      local isInState="$(echo "${podLine}" |grep "\<${expectedState}\>")"
      [ -n "${isInState}" ] && foundPod="$(echo "${podLine}" |awk '{print $1}')"
    fi
    (( i++ ))
    sleep "$(( i * 10))s"
    kubectl get pods -n rook-ceph >&2
  done
  [ -z "${foundPod}" ] && echo "Unable to find manager pod..." >&2 && return 1
  echo "${foundPod}"
}

function setup_test_framework() {
  # [ ! -f module.py ] && echo "The file, 'module.py', doesn't exists..." &&  wget https://raw.githubusercontent.com/pcuzner/ceph/add-events-mgr-module/src/pybind/mgr/k8sevents/module.py
  [ ! -f module.py ] && echo "The file, 'module.py', doesn't exists..." &&  wget https://raw.githubusercontent.com/ceph/ceph/a6cf6c1abdeba6d412b68315966b398ce8ad01d9/src/pybind/mgr/k8sevents/module.py
  [ ! -f module.py ] && echo "Unable to fetch 'module.py' file..." && return 1
  local profName=$PROFILE_NAME && [ -z "$profName" ] && profName="minikube"
  scp -o StrictHostKeyChecking=no -i $MINIKUBE_HOME/.minikube/machines/$profName/id_rsa $PWD/module.py docker@$(minikube $PROFILE_NAME_WITH_P ip):~/. || { echo "Unable to copy the 'module.py' to minikube cluster..."; return 1; }
  minikube $PROFILE_NAME_WITH_P ssh "echo 'mkdir -p $MINIKUBE_DATA_DIR/rook-ceph/log/' |su -"
  minikube $PROFILE_NAME_WITH_P ssh "echo 'cp -f ~docker/module.py $MINIKUBE_DATA_DIR/rook-ceph/log/module.py' |su -"
  local mgrPod="$(get_pod_with_state "mgr" "Running")"
  [ -z "${mgrPod}" ] && echo "Unable to find manager pod..." && return 1
  local k8sEventsDir="/usr/share/ceph/mgr/k8sevents"
  echo "mkdir -p $k8sEventsDir" |kubectl -n rook-ceph exec -it ${mgrPod} sh # 2>/dev/null
  echo "echo 'from .module import Module' >${k8sEventsDir}/__init__.py" |kubectl -n rook-ceph exec -it ${mgrPod} sh #2>/dev/null
  echo "cp /var/log/ceph/module.py ${k8sEventsDir}" |kubectl -n rook-ceph exec -it ${mgrPod} sh # 2>/dev/null
  local toolsPod="$(get_pod_with_state "tools" "Running")"
  [ -z "$toolsPod" ] && echo "Unable to find toolbox pod..." >&2 && return 1
  echo "ceph mgr module enable k8events --force" |kubectl -n rook-ceph exec -it ${toolsPod} sh #2>/dev/null
}

function cleanup() {
  if minikube status $PROFILE_NAME_WITH_P >/dev/null;then
    minikube stop $PROFILE_NAME_WITH_P
  fi
  local profName=$PROFILE_NAME && [ -z "$profName" ] && profName="minikube"
  echo "$BASE64_SUDO_PASS" |base64 --decode |sudo -S virsh list --all
  echo "Removing $profName virtual storage"
  echo "$BASE64_SUDO_PASS" |base64 --decode |sudo -S virsh undefine $profName --remove-all-storage --delete-snapshots
  minikube delete $PROFILE_NAME_WITH_P
  rm -rf $MINIKUBE_HOME/.minikube/machines/$profName
  rm -rf $MINIKUBE_HOME/.minikube/profiles/$profName
  rm -rf $STORAGE_BASE_DIR
  [ -f "${MINIKUBE_CONFIG_DIR}/config.json.bak" ] && mv ${MINIKUBE_CONFIG_DIR}/config.json.bak ${MINIKUBE_CONFIG_DIR}/config.json
  return 0
}

function help() {
  echo "Commandline Arguments"
  echo "---------------------"
  echo "-p <PROFILE_NAME>                 : argument will be used as profile to start the minikube instance"
  echo "-bp <BASE64_ENCODED_SUDO_PASSWORD>: base64 encoded sudo password"
  echo "-h | --help | -help               : prints this help"
  echo "-h | --help | -help               : prints this help"
  echo "clean | cleanup                   : cleanup any previously created setup"
  echo ""
  echo "Environment variables"
  echo "---------------------"
  echo "BASE64_SUDO_PASS : [mandatory] base64 encoded 'sudo' password."
  echo "                 : eg: BASE64_SUDO_PASS=\"\$(echo <your_sudo_password> |base64)\""
  echo "PROFILE_NAME     : [optional] will provide the profile name that should be used for creating minikube"
  echo "                 : (default: minikube)"
  echo "ROOK_GITHUB_HOME : github cloned location of the rook project. If not provided, will clone into current directory."
  echo "                 : (default: \$PWD/rook)"
}

function parse_command_line_args() {
  if echo "$@" | grep "\-h" >/dev/null;then
    help
    exit 0
  fi
  local profName="$(echo "$@" |sed -n 's@.*-p[[:space:]]\+\([^ ]*\).*@\1@gp')"
  [ -n "$profName" ] && PROFILE_NAME="$profName"
  # if PROFILE_NAME is set (through above line or environment variable)
  [ -n "$PROFILE_NAME" ] && PROFILE_NAME_WITH_P="-p $PROFILE_NAME"
  local b64SudoPass="$(echo "$@" |sed -n 's@.*-bp[[:space:]]\+\([^ ]*\).*@\1@gp')"
  [ -n "$b64SudoPass" ] && BASE64_SUDO_PASS="$b64SudoPass"
  [ -z "$BASE64_SUDO_PASS" ] && echo -e "\nA base64 encrypted sudo password is required to run this script...\nPass it through environment variable 'BASE64_SUDO_PASS'\nOr\nUse '-bp <BASE64_SUDO_PASS>' in the commandline\nTo generate BASE64_SUDO_PASS:\necho '<YOUR_SUDO_PASSWORD>' |base64" >&2 && exit 1
  echo $BASE64_SUDO_PASS |base64 --decode 1>/dev/null 2>&1 || { echo "Invalide base64 password" >&2; exit 1; }
  echo "$@" |grep "\<clean\>\|\<cleanup\>" 1>/dev/null 2>&1 && TOBE_CLEANED="true"
}

parse_command_line_args $@

if ! needed_binaries;then
  exit 1
fi

[ ! -f "$ENV_F" ] && echo "No environment file found! Sorry!" && exit 1
source $DIR_0/minikube.env

if [ -n "$TOBE_CLEANED" ];then
  cleanup
  exit $?
fi

echo "Starting minikube cluster..."
start_minikube || { echo "Unable to start the minikube cluster..."; exit 1; }
echo "Creating the virtual disks..."
create_virtual_disks
echo "Setting up rook..."
setup_rook || exit 1
echo "Setting up the test environment..."
setup_test_framework || exit 1

