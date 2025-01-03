# Broadcaster on multi-cluster Kubernetes

This repository contains the deployment manifests for the join demo between
[Software Mansion](https://swmansion.com/) and [L7mp Technologies](https://l7mp.io/)
to create a scalable and globally distributed WebRTC architecture
based on Elixir WebRTC, STUNner, Kubernetes and Cilium Cluster Mesh.

Check our [demo site](https://global.broadcaster.stunner.cc/) and [blog post](https://medium.com/l7mp-technologies) on the topic.

To reproduce the demo site, you have to execute the following steps:

## 1. Build a Docker image from Broadcaster

For the demo, we use a modified version of [Broadcaster](https://github.com/elixir-webrtc/apps/tree/master/broadcaster) - a simple Elixir WebRTC-based WHIP/WHEP streaming service.
The modified version is located in the [k8s_broadcaster](/k8s_broadcaster) folder.

You can use our version of the application, which is located in [GHCR](https://github.com/l7mp/multicluster-broadcaster-swm-l7mp/pkgs/container/multicluster-broadcaster-swm-l7mp%2Fk8s_broadcaster).
If you need any modification just build your own Docker image and use that in the Kubernetes manifests.

## 2. Bootstrap your infrastructure

In this demo we started simple VMs in [Hetzner Cloud](https://www.hetzner.com/cloud/) and use them as single-node Kubernetes clusters running [k3s](https://k3s.io/).
Thefore, the install scripts assume you already have the VMs running, and we'll access them with `ssh` using public keys (no password needed).
The public IP addresses of these VMs should be put into the file [`hetzner-ips.txt`](https://github.com/l7mp/multicluster-broadcaster-swm-l7mp/blob/main/hetzner-ips.txt).
You can use your own provider, any simple VMs should work.
In fact, in a production scenario, managed Kubernetes environments (e.g. EKS, AKS or GKE) would be the way to go.

## 3. Install K3s with Cilium on the VMs

[`install-nodes.sh`](https://github.com/l7mp/multicluster-broadcaster-swm-l7mp/blob/main/install-nodes.sh) is a simple script that loops over the VM IPs in `hetzner-ips.txt`, 
copies all files in the `manifests/` folder, and installs all components with the [`local-install.sh`](https://github.com/l7mp/multicluster-broadcaster-swm-l7mp/blob/main/manifests/local-install.sh) script.
During the next section we'll go through what actually happens in this install script, so you can modify it for your own use case.

First, [Cilium Cluster Mesh](https://docs.cilium.io/en/stable/network/clustermesh/clustermesh/#cluster-addressing-requirements) requires the Kubernetes clusters to have a distinct `Cluster ID` and `PodCIDR range`.
Therefore, we need to configure these manually cluster-by-cluster. This is done by this "fancy" `bash` syntax at the beginning of `local-install.sh`:

```sh
CLUSTERNAME=$(echo $HOSTNAME | cut -d'-' -f4,5)
CLUSTERID=1
CLUSTERIPAM="10.101.0.0/16"

# Switch case to set the integer based on the input string
case "$CLUSTERNAME" in
    "germany")
        CLUSTERID=1
        CLUSTERIPAM="10.101.0.0/16"
        ;;
    "us-west")
        CLUSTERID=2
        CLUSTERIPAM="10.102.0.0/16"
        ;;
    "singapore")
        CLUSTERID=3
        CLUSTERIPAM="10.103.0.0/16"
        ;;
    # Default case    
    *) 
        CLUSTERID=4
        CLUSTERIPAM="10.104.0.0/16"
        ;;
esac
```

Notice that the names of the clusters come from the last part of the `hostname` of the given VM after the last `-`. E.g. we use hostnames like `broadcaster-stunner-demo-germany`, so in these case `germany` will be extracted.
(The name `us-west` confuses this a bit, that is why we use `-f4,5` in the `cut` directive.)

Next, we install `k3s` with the following arguments:
 - do not install the built-in Traefik ingress: we'll use Nginx insted, but only because we prefer this ingress, feel free to use Traefik if you have experience with it, but make sure to match ingress annotations
 - do not install the Flannel CNI: we will install Cilium to handle cluster networking, so we don't need Flannel
 - disable Kube-proxy: Cilium will handle all functionalities of `kube-proxy` (e.g. route ClusterIPs), so we won't need it
 - disable the built-in network policy handler: Cilium will also provide the network policy functionalities

```sh
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik --flannel-backend=none --disable-kube-proxy --disable-network-policy" sh -
```

The following lines are just housekeeping after the `k3s` installation:
 - copy the `k3s` admin config file to `$HOME/.kube/config`, since other tools (Helm, Cilium CLI) will look for it in this path
 - set up `kubectl` bash completion
 - wait for the `kube-system` pods to be created (being too fast with the next steps can cause problems)
 - install `helm`

```sh
# 2: set up kubectl
rm -rf $HOME/.kube
mkdir -p $HOME/.kube
sudo cp -i /etc/rancher/k3s/k3s.yaml $HOME/.kube/config
sudo chown $(id -u):$(id -g) /etc/rancher/k3s/k3s.yaml
sudo chown $(id -u):$(id -g) $HOME/.kube/config

echo 'source <(kubectl completion bash)' >>~/.bashrc
echo 'alias k=kubectl' >>~/.bashrc
echo 'complete -o default -F __start_kubectl k' >>~/.bashrc

kubectl version
echo "Waiting for system pods to be created in kube-system namespace..."
while [ $(kubectl get pods -n kube-system) -le 1 ]; do
    echo -n "."
    sleep 1
done
kubectl get nodes && kubectl get pods -A

# 3: get helm
curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash
echo 'source <(helm completion bash)' >>~/.bashrc
helm repo add cilium https://helm.cilium.io/
helm repo update
```

Next, we download the latest Cilium CLI (`v1.16.4` when this guide was made):

```sh
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=amd64
if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
```

Then, we can install the Cilium CNI with the following arguments:
 - set the `Cluser ID` and `PodCIDR` to be distinctive for all clusters
 - enable `EndpointSlice` synchronization since we'll need that feature for the Erlang Distribution service discovery 
 - enable `kube-proxy` replacement
 - we have to set the `IP` and the `port` of the Kubernetes API server manually, since during the Cilium install there is no `kube-proxy` that could route the user to the `kubernetes.default.svc` service

```sh
IP=$(ip -f inet addr show eth0 | grep -Po 'inet \K[\d.]+')
PORT=6443
cilium install --set cluster.name=$CLUSTERNAME --set cluster.id=$CLUSTERID --set ipam.operator.clusterPoolIPv4PodCIDRList="$CLUSTERIPAM" \
    --set clustermesh.enableEndpointSliceSynchronization=true \
    --set kubeProxyReplacement=true \
    --set k8sServiceHost=$IP \
    --set k8sServicePort=$PORT
```

It takes a while for Cilium to span up, so we should wait for it (other pods won't start until the CNI is installed, which can cause problems in the later steps):

```sh
kubectl get pods -n kube-system
echo "Waiting for cilium pods to be ready..."
sleep 5
kubectl wait --for=condition=Ready -n kube-system pod  -l app.kubernetes.io/name=cilium-agent --timeout=90s
```

Next, we install the Nginx Ingress controller (feel free to replace this with your favourite ingress provider) and set its service to `type: LoadBalancer` so it can be reached from the outside.
In `k3s` this will mean that the given ports (`80, 443` in this case) will be published on the VM's IP:

```sh
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.2/deploy/static/provider/baremetal/deploy.yaml
kubectl patch service -n ingress-nginx ingress-nginx-controller -p '{"spec": {"type": "LoadBalancer"}}'
echo "Waiting for nginx ingress to be ready..."
kubectl wait --for=condition=Ready -n ingress-nginx pod  -l app.kubernetes.io/component=controller --timeout=90s
kubectl get pods -n ingress-nginx
```

Finally, we install `cert-manager` to create valid TLS certs for our ingresses using Let's Encrypt.

```sh
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.1/cert-manager.yaml
echo "Waiting for cert-manager to be ready..."
kubectl wait --for=condition=Ready -n cert-manager pod  -l app.kubernetes.io/component=webhook --timeout=90s
```

Using `cert-manager` in a multi-cluster scenario can be tricky. Normally, all you have to do is set up a DNS entry to your Nginx Ingress LoadBalancer IP (same as the VM's public IP in this case), 
and Let's Encrypt will give you a valid cert using [HTTP Challange](https://cert-manager.io/docs/configuration/acme/http01/). This will work for the regional subdomains (e.g. `germany.broadcaster.stunner.cc`)
but we have a global domain name (`global.broadcaster.stunner.cc`) which will route users to the closest location (check DNS section in this guide for more details). 
In this case, the HTTP Challange won't work, since Let's Encrypt itself will only be routed to one specific cluster (usually the closest to the USA), and the other clusters won't be able to valide the challange.
So in order to create valid certs for the global domain we need to set up [DNS Challange](https://cert-manager.io/docs/configuration/acme/dns01/) for Let's Encrypt. 
That is a bit more complicated, and also requires different steps based on your DNS provider (check the guides [here](https://cert-manager.io/docs/configuration/acme/dns01/#supported-dns01-providers)). 
Our domain (`stunner.cc`) is registered at Cloudflare, so we'll show this process. You'll need the following manifests to make this work:

```yaml
apiVersion: v1
data:
  # Generate your own cloudflare api key based on the guide
  api-token: your-cloudflare-api-key-in-base64
kind: Secret
metadata:
  name: cloudflare-api-token-secret
  namespace: cert-manager
type: Opaque
---
apiVersion: v1
data:
  # Let's Encrypt authenticates users based on TLS
  # You can use any key, actually Cert Manager will generate one for you automatically
  # But it makes sense to use the same key for all clusters, since in that case
  # Cert-Manager will only generate the cert once (in the first cluster) and 
  # in other cluster it can just dowload the same cert from the Let's Encrypt account.
  # This makes the whole process faster, and also without this you can easily hit
  # the rate limits of Let's Encrypt which can be frustrating
  tls.key: a-tls-key-for-lets-encrypt 
kind: Secret
metadata:
  name: cloudflare-issuer-account-key
  namespace: cert-manager
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: dns-challange
spec:
  acme:
    email: info@mydomain.io
    preferredChain: ""
    privateKeySecretRef:
      name: cloudflare-issuer-account-key
    server: https://acme-v02.api.letsencrypt.org/directory
    solvers:
    - dns01:
        cloudflare:
          apiTokenSecretRef:
            key: api-token
            name: cloudflare-api-token-secret
          email: info@mydomain.io
      selector:
        dnsZones:
        - mydomain.io
```

Apply these manifests:

```sh
kubectl apply -f cloudflare-secret.yaml
kubectl apply -f issuer.yaml
```

## 4. Install STUNner

Next, we install STUNner and create a Gateway to listen to TURN traffic.

```sh
helm repo add stunner https://l7mp.io/stunner
helm repo update
helm install stunner-gateway-operator stunner/stunner-gateway-operator --create-namespace --namespace=stunner
kubectl apply -f stunner-common.yaml
```

## 5. Install Broadcaster

Now, install the Broadcaster application to the cluster.
Notice, that we need to change some parameters in the `yaml` that will point to the local cluster (local domain name, and ingress hostname):

```sh
sed -i "s/MYREGION/$CLUSTERNAME/g" broadcaster.yaml
kubectl apply -f broadcaster.yaml -n default
kubectl apply -f broadcaster-udproute.yaml
```

## 6. Create the Cilium Cluster Mesh

Next, we have to create a Cluster Mesh between the three clusters using Cilium. This will be used for the following:
 - `Pods` can reach each other no matter in which cluster they are
 - `EndpointSlices` will be synchronized for the `broadcaster-headless` service, so Broadcaster pods can form an [Erlang Distribution](https://www.erlang.org/doc/system/distributed.html) cluster

You can automate this with the script [`mesh-install.sh`](https://github.com/l7mp/multicluster-broadcaster-swm-l7mp/blob/main/mesh-install.sh), but here is a step-by-step guide on what should be done.
Also, please check out the [official install guide](https://docs.cilium.io/en/stable/network/clustermesh/clustermesh/) of Cilium Cluster Mesh.

Fisrt, we need to collect all the Kubernetes config files in one, and create `context` names for each. This is done by these lines:

```sh
# set env vars
KUBECONFIG=.kube/config
CLUSTER1=germany
CLUSTER2=us-west
CLUSTER3=singapore

CLUSTER1IP=116.203.254.213
CLUSTER2IP=5.78.69.126
CLUSTER3IP=5.223.46.141

# get kubeconfig files
scp -o "StrictHostKeyChecking no" root@$CLUSTER1.broadcaster.stunner.cc:.kube/config ./$CLUSTER1
sed -i "s/127.0.0.1/$CLUSTER1IP/" $CLUSTER1
sed -i "s/default/$CLUSTER1/" $CLUSTER1

scp -o "StrictHostKeyChecking no" root@$CLUSTER2.broadcaster.stunner.cc:.kube/config ./$CLUSTER2
sed -i "s/127.0.0.1/$CLUSTER2IP/" $CLUSTER2
sed -i "s/default/$CLUSTER2/" $CLUSTER2

scp -o "StrictHostKeyChecking no" root@$CLUSTER3.broadcaster.stunner.cc:.kube/config ./$CLUSTER3
sed -i "s/127.0.0.1/$CLUSTER3IP/" $CLUSTER3
sed -i "s/default/$CLUSTER3/" $CLUSTER3

export KUBECONFIG=$CLUSTER1:$CLUSTER2:$CLUSTER3
```

Note: this part assumes that the VMs have a public IP in their primary interface. You will need additional steps if you use VMs behind NAT (use `--tls-san` during the `k3s` install), 
or something very differnet in case you use managed Kubernetes clusters insted of `k3s`.

Then, install the Cilium CLI:

```sh
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=amd64
if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
```

Next, we need to synchronize the Cilium CA certificates in all clusters. 
If they do not match between clusters the multi-cluster features might be limited!

```sh
kubectl --context $CLUSTER2 delete secret -n kube-system cilium-ca
kubectl --context=$CLUSTER1 get secret -n kube-system cilium-ca -o yaml |  kubectl --context $CLUSTER2 create -f -
kubectl --context $CLUSTER2 delete pod -n kube-system -l app.kubernetes.io/part-of=cilium
kubectl --context $CLUSTER3 delete secret -n kube-system cilium-ca
kubectl --context=$CLUSTER1 get secret -n kube-system cilium-ca -o yaml |  kubectl --context $CLUSTER3 create -f -
kubectl --context $CLUSTER3 delete pod -n kube-system -l app.kubernetes.io/part-of=cilium
```

Next, enable cluster mesh in all clusters:

```sh
cilium clustermesh enable --context $CLUSTER1 --service-type LoadBalancer
cilium clustermesh enable --context $CLUSTER2 --service-type LoadBalancer
cilium clustermesh enable --context $CLUSTER3 --service-type LoadBalancer

# optionally check cluster mesh status
cilium clustermesh status --context $CLUSTER1
cilium clustermesh status --context $CLUSTER2
cilium clustermesh status --context $CLUSTER3
```

Finally, connect the clusters to each other.
Cluster connection is symmetric, so it only needs to be done one-way.

```sh
cilium clustermesh connect --context $CLUSTER1 --destination-context $CLUSTER2
cilium clustermesh connect --context $CLUSTER1 --destination-context $CLUSTER3
cilium clustermesh connect --context $CLUSTER2 --destination-context $CLUSTER3
```

Optionally you can re-check cluster mesh status, and run some connectivity test:

```sh
cilium clustermesh status --context $CLUSTER1 --wait
cilium clustermesh status --context $CLUSTER2 --wait
cilium clustermesh status --context $CLUSTER3 --wait

# test conenctions (takes a while)
cilium connectivity test --context $CLUSTER1 --multi-cluster $CLUSTER2
cilium connectivity test --context $CLUSTER1 --multi-cluster $CLUSTER3
```

If you done everything right, pods in one cluster should have connectivity to any pod in any other cluster.
Moreover, services with the same name and the annotation `service.cilium.io/global: "true"` should be load balanced across clusters.
Check out more on the `service discovery` and `load balancing` in Cilium Cluster Mesh [here](https://docs.cilium.io/en/stable/network/clustermesh/services/).

In our case, the `broadcaster-headless` service is set up to synchronize the `EndpointSlices` in all clusters:

```yaml
user@broadcaster-stunner-demo-singapore:~# kubectl get service broadcaster-headless -o yaml
apiVersion: v1
kind: Service
metadata:
  annotations:
    service.cilium.io/global: "true"
    service.cilium.io/global-sync-endpoint-slices: "true"
  name: broadcaster-headless
  namespace: default
spec:
  clusterIP: None
  selector:
    app: broadcaster
  type: ClusterIP
```

So if you check the `EndpointSlices`, you should see the IP addresses of the `pods` from the other clusters:

```sh
user@broadcaster-stunner-demo-singapore:~# kubectl get endpointslices.discovery.k8s.io
NAME                                 ADDRESSTYPE   PORTS     ENDPOINTS      AGE
broadcaster-headless-68k5g           IPv4          <unset>   10.103.0.58    7d1h
broadcaster-headless-germany-69l5t   IPv4          <unset>   10.101.0.81    6d23h
broadcaster-headless-us-west-q7qvs   IPv4          <unset>   10.102.0.220   6d23h
```

Note: we use Cilium Cluster Mesh in our demo since we set up Kubernetes clusters manually using `k3s`.
In a production scenario one would use managed Kubernetes environments like AKS, EKS or GKE.
You can set up all these solutions to have pod-to-pod connections across clusters (e.g. by having pods directly addressable in a VPC) and 
synchronize `Endpoints` or `EndpointSlices` between clusters. To that end, you won't need to install the Cilium CNI and Cluster Mesh (although you might be able to, since 
most of these solutions are using Cilium by default). These guides are a good starting point if you are using a managed Kubernetes solution:
 - [AKS](https://learn.microsoft.com/en-us/azure/kubernetes-fleet/l4-load-balancing)
 - [EKS](https://aws-solutions-library-samples.github.io/compute/multi-cluster-application-management-with-karmada-and-amazon-eks.html)
 - [GKE](https://cloud.google.com/kubernetes-engine/docs/how-to/multi-cluster-services)


## 7. Set up DNS records

Finally, we have to set up our DNS domains. We use per-cluster subdomains to point to a given cluster, and we also use a global domain with 
DNS load balacing, that will route users to the closest location. For this we use [Azure Traffic Manager](https://learn.microsoft.com/en-us/azure/traffic-manager/traffic-manager-overview).
You can use other providers if you prefer (e.g. [Cloudflare](https://developers.cloudflare.com/load-balancing/understand-basics/load-balancing-components/), [AWS Route 53](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/routing-policy-geo.html) or [GCP Cloud DNS](https://cloud.google.com/dns/docs/configure-routing-policies)), but we stick to Traffic Manager, since it is very easy to set up and also free to use in these low traffic demo environments.

You can go to the [Azure Portal](https://learn.microsoft.com/en-us/azure/traffic-manager/tutorial-traffic-manager-improve-website-response) and set the DNS up for yourself, 
but we also include a simple Terraform script to span this up.
First, check out [`variables.tf`](https://github.com/l7mp/multicluster-broadcaster-swm-l7mp/blob/main/variables.tf) to set up your locations and IPs, then just run the following (assuming the Azure CLI is already set up):

```sh
export ARM_SUBSCRIPTION_ID=your-subscription-id
terraform init
terraform apply
```

In our [demo environment](https://global.broadcaster.stunner.cc/) we use the following DNS settings:

| Type  | Hostame                            | Content                               |
|-------|------------------------------------|---------------------------------------|
| CNAME | global.broadcaster.stunner.cc      | broadcaster-global.trafficmanager.net |
| A     | germany.broadcaster.stunner.cc     | 116.203.254.213                       |
| A     | singapore.broadcaster.stunner.cc   | 5.223.46.141                          |
| A     | us-west.broadcaster.stunner.cc     | 5.78.69.126                           |