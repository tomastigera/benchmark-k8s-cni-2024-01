#!/bin/bash

set -x

CURDIR=$(dirname "$0")
[ "$CURDIR" = "." ] && CURDIR=$(pwd)

USE_VLAN="${USE_VLAN:=n}"

export KUBECONFIG="$CURDIR/setup/59-kubeconfig.yaml"
export SERVER_MTU=${SERVER_MTU:-"1500"}
export SSHUSER=root
export PROJECT="730997aa-dfc5-429f-a05d-0effa65253c5"
export TYPE="m3.small.x86"
export CLUSTER_NAME=${CLUSTER_NAME:-"test"}
export VLANID=4e3c07b7-d831-4bb3-ac55-5af4350a7682
export USE_VLAN

function init {
    echo "Setup instances on Equinix Metal"
    SERVEROPTS="-p $PROJECT -m da -O ubuntu_22_04 -P $TYPE"

    metal device create -H "${CLUSTER_NAME}"-a1 ${SERVEROPTS}
    metal device create -H "${CLUSTER_NAME}"-a2 ${SERVEROPTS}
    metal device create -H "${CLUSTER_NAME}"-a3 ${SERVEROPTS}

    echo "Waiting for all servers to be deployed"
    until metal device get --filter hostname="${CLUSTER_NAME}"-a1 --output json | jq -r .[].state | grep active; do echo "Trying again"; sleep 1; done
    until metal device get --filter hostname="${CLUSTER_NAME}"-a2 --output json | jq -r .[].state | grep active; do echo "Trying again"; sleep 1; done
    until metal device get --filter hostname="${CLUSTER_NAME}"-a3 --output json | jq -r .[].state | grep active; do echo "Trying again"; sleep 1; done

    metal device list -o json | jq -r .[].state

    if [ "$USE_VLAN" = "y" ]; then
	    # Put bond0 on each server onto the same VLAN
	    metal ports vlan --port-id "$(metal device get --filter hostname="${CLUSTER_NAME}"-a1 --output json | jq -r .[0].network_ports[0].bond.id)" --assign ${VLANID}
	    metal ports vlan --port-id "$(metal device get --filter hostname="${CLUSTER_NAME}"-a2 --output json | jq -r .[0].network_ports[0].bond.id)" --assign ${VLANID}
	    metal ports vlan --port-id "$(metal device get --filter hostname="${CLUSTER_NAME}"-a3 --output json | jq -r .[0].network_ports[0].bond.id)" --assign ${VLANID}
    fi

    sleep 10

    A1IP=$(getip a1 0)
    A2IP=$(getip a2 0)
    A3IP=$(getip a3 0)

    WAITPID=""
    "$CURDIR"/setup/20-os-prepare.sh ${SSHUSER}@"$A1IP" &
    WAITPID="${WAITPID}" $!
    "$CURDIR"/setup/20-os-prepare.sh ${SSHUSER}@"$A2IP" &
    WAITPID="${WAITPID}" $!
    "$CURDIR"/setup/20-os-prepare.sh ${SSHUSER}@"$A3IP" &
    WAITPID="${WAITPID}" $!

    echo "Waiting for all servers to be prepared"
    wait "${WAITPID}"

}
function rke2-up {
    A1IP_EXT=$(getip a1 0)
    A2IP_EXT=$(getip a2 0)
    A3IP_EXT=$(getip a3 0)

    A1IP=$(getip a1 2)
    A2IP=$(getip a2 2)
    A3IP=$(getip a3 2)

    if [ "$USE_VLAN" = "y" ]; then
	    A1IP="192.168.2.1"
	    A2IP="192.168.2.2"
	    A3IP="192.168.2.3"
    fi

    CONTROL_IP=$A1IP

    echo "Setup RKE2 controlplane on a1 ($A1IP_EXT)"
    "$CURDIR"/setup/50-setup-rke2.sh cp ${SSHUSER}@"$A1IP_EXT" $A1IP $A1IP $A1IP_EXT

    echo "Setup RKE2 worker on a2 ($A2IP_EXT) and a3 ($A3IP_EXT)"
    "$CURDIR"/setup/50-setup-rke2.sh worker ${SSHUSER}@"$A2IP_EXT" $CONTROL_IP $A2IP $A2IP_EXT
    "$CURDIR"/setup/50-setup-rke2.sh worker ${SSHUSER}@"$A3IP_EXT" $CONTROL_IP $A3IP $A3IP_EXT
    sed -i "s/192.168.2.1/$A1IP/g" "$CURDIR"/setup/59-kubeconfig.yaml

    echo "RKE2 ready"
}

function setup-cni {

    echo "Setup CNI $1"
    "$CURDIR"/setup/60-setup-cni.sh "$1"

    echo "Waiting for all pods to be running or completed"
    while [ "$(kubectl get pods -A --no-headers | grep -v Running | grep -v Completed)" != "" ]; do
        echo -n "."
        sleep 2
    done
    echo ""
}

function rke2-down {
    A1IP=$(getip a1 0)
    A2IP=$(getip a2 0)
    A3IP=$(getip a3 0)

    echo "Tear down RKE2"
    WAITPID=""
    "$CURDIR"/setup/80-teardown-rke2.sh ${SSHUSER}@"$A1IP" &
    WAITPID="$WAITPID $!"
    "$CURDIR"/setup/80-teardown-rke2.sh ${SSHUSER}@"$A2IP" &
    WAITPID="$WAITPID $!"
    "$CURDIR"/setup/80-teardown-rke2.sh ${SSHUSER}@"$A3IP" &
    WAITPID="$WAITPID $!"

    echo "Waiting for all servers to be cleaned up"
    wait "$WAITPID"

    echo "RKE2 down"
}

function clean {
    yes | metal device delete -i "$(metal device get --filter hostname="${CLUSTER_NAME}-a1" --output json | jq -r .[].id)"
    yes | metal device delete -i "$(metal device get --filter hostname="${CLUSTER_NAME}-a2" --output json | jq -r .[].id)"
    yes | metal device delete -i "$(metal device get --filter hostname="${CLUSTER_NAME}-a3" --output json | jq -r .[].id)"

    echo "Waiting for all servers to be deleted"
    until metal device get --filter hostname="${CLUSTER_NAME}-a1" --output json | grep "null"; do echo "Trying again"; sleep 1; done
    until metal device get --filter hostname="${CLUSTER_NAME}-a2" --output json | grep "null"; do echo "Trying again"; sleep 1; done
    until metal device get --filter hostname="${CLUSTER_NAME}-a3" --output json | grep "null"; do echo "Trying again"; sleep 1; done
}


function debugpods {
cat <<-EOF | kubectl apply -f - >/dev/null|| { echo "Cannot create server pod"; return 1;  }
apiVersion: v1
kind: Pod
metadata:
  labels:
    app: debug-server
  name: debug-server
spec:
  containers:
  - name: iperf
    image: infrabuilder/bench-iperf3
    args:
    - iperf3
    - -s
  nodeName: a2
EOF
cat <<-EOF | kubectl apply -f - >/dev/null|| { echo "Cannot create client pod"; return 1;  }
apiVersion: v1
kind: Pod
metadata:
  labels:
    app: debug-client
  name: debug-client
spec:
  containers:
  - name: iperf
    image: infrabuilder/bench-iperf3
    args:
    - sh
    tty: true
  nodeName: a3
EOF

    echo -n "Waiting for server pod to be running "
    while [ "$(kubectl get pod debug-server -o jsonpath='{.status.phase}')" != "Running" ]; do
        echo -n "."
        sleep 2
    done
    echo ""

    # Print server pod IP
    echo "Server IP: $(kubectl get pod debug-server -o jsonpath='{.status.podIP}')"
    echo "Run client with : kubectl exec -it debug-client -- sh"
}

function connect-ssh {
    SSHIP=$(getip "$1")
    shift
    exec ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${SSHUSER}@$SSHIP" "$@"
}

function getip {
	metal device get --filter hostname="${CLUSTER_NAME}-${1}" --output json | jq --argjson i "$2" -r '.[].ip_addresses[$i].address'
}

[ "$1" = "" ] && echo "Usage: $0 (init|rke2-up|rke2-down|cni <cni>|cleanup)" && exit 1

while [ "$1" != "" ]; do
    case $1 in
        init|i)
            init
            ;;
        rke2-up|up|u)
            rke2-up
            ;;
        rke2-down|down|d)
            rke2-down
            ;;
        setup-cni|cni)
            setup-cni "$2"
            shift
            ;;
        cleanup|clean|c)
            clean
            ;;
        debugpods|debug)
            debugpods
            ;;
        ssh|s)
            connect-ssh "$2" "${@:3}"
            shift
            ;;
        getip|ip)
            getip "$2" "$3"
            shift
            shift
            ;;
        *)
            echo "Unknown command '$1'"
            exit 1
            ;;
    esac
    shift
done
