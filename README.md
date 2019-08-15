# ceph-events-to-kube-setup
Tries to create a minikube setup which connects ceph events to kubernetes. This is just a scriptification of steps documented in the project

Script's help

```comment
bash start_demo_setup.sh -h

Commandline Arguments
---------------------
-p <PROFILE_NAME>                 : argument will be used as profile to start the minikube instance
-bp <BASE64_ENCODED_SUDO_PASSWORD>: base64 encoded sudo password
-h | --help | -help               : prints this help
clean | cleanup                   : cleanup any previously created setup

Environment variables
---------------------
BASE64_SUDO_PASS : [mandatory] base64 encoded 'sudo' password.
                 : eg: BASE64_SUDO_PASS="$(echo <your_sudo_password> |base64)"
PROFILE_NAME     : [optional] will provide the profile name that should be used for creating minikube
                 : (default: minikube)
ROOK_GITHUB_HOME : github cloned location of the rook project. If not provided, will clone into current directory.
                 : (default: $PWD/rook)
```
