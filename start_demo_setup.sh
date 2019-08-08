#!/bin/bash

DIR_0="$(cd $(dirname $0) && pwd)"
ENV_F="$DIR_0/minikube.env"
PROFILE_NAME="storage_event_management"
# the below order of files should not be changed
NEEDED_FILES=(common.yaml operator.yaml cluster.yaml toolbox.yaml pool.yaml filesystem.yaml)
MINIKUBE_DATA_DIR="/data/rook"
STORAGE_BASE_DIR="$PWD/libvirt"

function needed_binaries() {
  local binary_list=(base64 minikube qemu-img virsh kubectl scp wget)
  local not_found=""
  for eachB in ${binary_list[@]};do
    if ! which $eachB 2>/dev/null 1>&2;then
      [ -z "$not_found" ] && echo -e "\nUnable to find"
      echo -e "$eachB"
      not_found="NotFound"
    fi
  done
  [ -n "$not_found" ] && return 1
  [ -z "$BASE64_SUDO_PASS" ] && echo -e "\nA base64 encrypted sudo password is required to run this script...\nPass it through environment variable 'BASE64_SUDO_PASS'\nEg: echo '<YOUR_SUDO_PASSWORD>' |base64" && return 1
  return 0
}

function start_minikube() {
  echo
  minikube config view
  echo
  if minikube status -p $PROFILE_NAME >/dev/null;then
    echo -e "\nStorage-Event-Management minikube cluster is running..."
  else
    minikube start -p $PROFILE_NAME
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
  for (( i=1; i<=${nDisks}; i++ ));do
    local disk="${diskLocation}/osd$i.qcow2"
    [ ! -f ${disk} ] && qemu-img create -f qcow2 ${disk} 1T
    echo "$BASE64_SUDO_PASS" |base64 --decode |sudo -S virsh attach-disk $PROFILE_NAME ${disk} vd${appendAlpha[i]} --driver qemu --subdriver qcow2 --targetbus virtio --persistent
  done
  minikube -p $PROFILE_NAME ssh "echo 'echo 1 >/sys/bus/pci/rescan' |su -"
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

function setup_test_framework() {
  [ ! -f module.py ] && echo "The file, 'module.py', exists..." &&  wget https://raw.githubusercontent.com/pcuzner/ceph/add-events-mgr-module/src/pybind/mgr/k8sevents/module.py
  [ ! -f module.py ] && echo "Unable to fetch 'module.py' file..." && return 1
  scp -o StrictHostKeyChecking=no -i $MINIKUBE_HOME/.minikube/machines/$PROFILE_NAME/id_rsa $PWD/module.py docker@$(minikube -p $PROFILE_NAME ip):~/. || { echo "Unable to copy the 'module.py' to minikube cluster..."; return 1; }
  minikube -p $PROFILE_NAME ssh "echo 'mkdir -p $MINIKUBE_DATA_DIR/rook-ceph/log/' |su -"
  minikube -p $PROFILE_NAME ssh "echo 'cp -f ~docker/module.py $MINIKUBE_DATA_DIR/rook-ceph/log/module.py' |su -"
  local mgrPod=""
  local i=0
  while [ -z "$mgrPod" ] && [ $i -lt 20 ];do
    mgrPod="$(kubectl get pods -n rook-ceph |grep "mgr" |sed -n 's/^\([^ ]*\).*/\1/gp')"
    (( i++ ))
    sleep "$(( i * 10))s"
    kubectl get pods -n rook-ceph
  done
  [ -z "${mgrPod}" ] && echo "Unable to find manager pod..." && return 1
  local k8sEventsDir="/usr/share/ceph/mgr/k8sevents"
  echo "mkdir -p $k8sEventsDir" |kubectl -n rook-ceph exec -it ${mgrPod} sh 2>/dev/null
  echo "echo 'from .module import Module' >${k8sEventsDir}/__init__.py" |kubectl -n rook-ceph exec -it ${mgrPod} sh 2>/dev/null
  echo "cp /var/log/ceph/module.py ${k8sEventsDir}" |kubectl -n rook-ceph exec -it ${mgrPod} sh 2>/dev/null
  local toolsPod="$(kubectl get pods -n rook-ceph |grep "tools" |sed -n 's/^\([^ ]*\).*/\1/gp')"
  [ -z "$toolsPod" ] && echo "Unable to find toolbox pod..." && return 1
  echo "ceph mgr module enable k8events --force" |kubectl -n rook-ceph exec -it ${toolsPod} sh 2>/dev/null
}

function cleanup() {
  if minikube status -p $PROFILE_NAME >/dev/null;then
    minikube stop -p $PROFILE_NAME
  fi
  echo "$BASE64_SUDO_PASS" |base64 --decode |sudo -S virsh undefine $PROFILE_NAME --remove-all-storage --delete-snapshots
  minikube delete -p $PROFILE_NAME
  rm -rf $MINIKUBE_HOME/.minikube/machines/$PROFILE_NAME
  rm -rf $MINIKUBE_HOME/.minikube/profiles/$PROFILE_NAME
  rm -rf $STORAGE_BASE_DIR
  return 0
}

if ! needed_binaries;then
  exit 1
fi

[ ! -f "$ENV_F" ] && echo "No environment file found! Sorry!" && exit 1
source $DIR_0/minikube.env

if [ "$1" = "clean" ];then
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

