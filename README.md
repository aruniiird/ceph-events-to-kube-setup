# ceph-events-to-kube-setup
Tries to create a minikube setup which connects ceph events to kubernetes. This is just a scriptification of steps documented in the project

Run the script 'start_demo_setup.sh', after setting up following environment variables,

BASE64_SUDO_PASS: (mandatory) the script uses 'sudo' to run 'virsh' command. So a base64 encoded sudo password is accepted here.

ROOK_GITHUB_HOME : (optional) if you have already cloned the rook project, then point to that location.

PS: creating a base64 encoded password,
BASE64_SUDO_PASS="$(echo "<your_sudo_password>" |base64)"
