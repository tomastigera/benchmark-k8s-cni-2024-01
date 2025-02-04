
# Source : https://docs.tigera.io/calico/latest/operations/ebpf/install

echo "Creating tigera-operator namespace"

kubectl create namespace tigera-operator

echo "Apply configmap"

clean_input=$(kubectl cluster-info | grep 'control plane' | sed -r 's/\x1B\[[0-9;]*[mK]//g')

# Apply configmap to tell Operator what the real IP/port of the control plane is
kubectl apply -f - <<EOF
kind: ConfigMap
apiVersion: v1
metadata:
  name: kubernetes-services-endpoint
  namespace: tigera-operator
data:
  KUBERNETES_SERVICE_HOST: "$(echo $clean_input | awk -F':|//' '{print $3}')"
  KUBERNETES_SERVICE_PORT: "$(echo $clean_input | awk -F':|//' '{print $4}')"
EOF

echo "Setup calico operator"
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/master/manifests/tigera-operator.yaml

# IPPool CIDR changed for RKE2 default 10.42.0.0/16
echo "Setup calico custom resource"
kubectl apply -f - <<EOF
# This section includes base Calico installation configuration.
# For more information, see: https://docs.tigera.io/calico/latest/reference/installation/api#operator.tigera.io/v1.Installation
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  # Configures Calico networking.
  calicoNetwork:
    linuxDataplane: BPF
    # Note: The ipPools section cannot be modified post-install.
    ipPools:
    - blockSize: 26
      cidr: 10.42.0.0/16
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
    nodeAddressAutodetectionV4:
          cidrs:
            - '192.168.2.0/24'
---
# This section configures the Calico API server.
# For more information, see: https://docs.tigera.io/calico/latest/reference/installation/api#operator.tigera.io/v1.APIServer
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOF

echo "Wait for calico-apiserver to come up"
sleep 20 # Wait for operator to create calico-apiserver deployment
kubectl rollout status deployment calico-apiserver -n calico-apiserver  # wait for deployment pods to come up

echo "Patch Felixconfig"
# Configure Calico to not try to clean up kube-proxy's iptables rules, since kube-proxy can't be disabled in RKE2
kubectl patch felixconfiguration default --patch='{"spec": {"bpfKubeProxyIptablesCleanupEnabled": false}}'
