#!/bin/bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Check for secrets file
if [ ! -f secrets.yaml ]; then
    echo "ERROR: secrets.yaml not found!"
    echo "Please copy secrets.example.yaml to secrets.yaml and fill in your data."
    exit 1
fi

# 1. Install K3s (if not exists)
if ! command -v k3s &> /dev/null; then
    echo -e "${GREEN}>>> Installing K3s (Custom Ports)...${NC}"
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--kube-apiserver-arg service-node-port-range=1-65535" sh -
    echo "Waiting for K3s readiness..."
    sleep 20
else
    echo -e "${GREEN}>>> K3s is already installed.${NC}"
fi

# Configure access (Persistent)
if [ -f /etc/rancher/k3s/k3s.yaml ]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    chmod 644 /etc/rancher/k3s/k3s.yaml
    mkdir -p ~/.kube
    cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
    chmod 600 ~/.kube/config
else
    echo "ERROR: K3s config not found!"
    exit 1
fi

# 2. Install Helm
if ! command -v helm &> /dev/null; then
    echo -e "${GREEN}>>> Installing Helm...${NC}"
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# 3. Traefik Setup
echo -e "${GREEN}>>> Preparing Traefik Configuration...${NC}"

# Extract Email and Domain
EMAIL=$(grep 'email:' secrets.yaml | awk '{print $2}' | tr -d '"')
DOMAIN=$(grep 'domain:' secrets.yaml | awk '{print $2}' | tr -d '"')

if [ -z "$EMAIL" ] || [ -z "$DOMAIN" ]; then
    echo "ERROR: Email or Domain not found in secrets.yaml"
    exit 1
fi

echo -e "${GREEN}>>> Configuring Traefik with email: $EMAIL...${NC}"

# Create Secret
kubectl create secret generic traefik-acme-secret \
  --from-literal=email=$EMAIL \
  --namespace kube-system \
  --dry-run=client -o yaml | kubectl apply -f -

# Apply Config
kubectl apply -f configs/traefik-config.yaml

# 4. ROBUST WAIT: Find Traefik and ensure it reloads
echo -e "${GREEN}>>> Waiting for Traefik Deployment to appear...${NC}"

# Wait until K3s actually creates the deployment (can take time on fresh install)
MAX_WAIT_LOOPS=60
LOOP_COUNT=0
TRAEFIK_DEPLOY=""

while [ $LOOP_COUNT -lt $MAX_WAIT_LOOPS ]; do
    # Try to find deployment by label (works even if name varies)
    TRAEFIK_DEPLOY=$(kubectl get deploy -n kube-system -l app.kubernetes.io/name=traefik -o name | head -n 1)
    
    if [ ! -z "$TRAEFIK_DEPLOY" ]; then
        echo -e "Found Traefik: $TRAEFIK_DEPLOY"
        break
    fi
    
    echo -n "."
    sleep 2
    LOOP_COUNT=$((LOOP_COUNT+1))
done

if [ -z "$TRAEFIK_DEPLOY" ]; then
    echo -e "\n${YELLOW}ERROR: Traefik deployment never appeared. Check K3s status.${NC}"
    exit 1
fi

echo -e "\n${GREEN}>>> Restarting Traefik to apply ACME settings...${NC}"
# Force restart to pick up changes immediately
kubectl rollout restart $TRAEFIK_DEPLOY -n kube-system

# Wait for the rollout to actually finish
echo "Waiting for Traefik deployment rollout..."
kubectl rollout status $TRAEFIK_DEPLOY -n kube-system --timeout=180s

# Double check readiness check
echo "Verifying Traefik readiness..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=traefik -n kube-system --timeout=60s

# Give Traefik internal processes (ACME provider) a moment to initialize
echo -e "${YELLOW}>>> Pausing 10s to let Traefik ACME engine initialize...${NC}"
sleep 10

# 5. Deploy Application
echo -e "\n${GREEN}>>> Deploying RemnaNode...${NC}"
helm upgrade --install remnanode ./charts/remnanode \
  --namespace remnanode \
  --create-namespace \
  -f secrets.yaml

# 6. VERIFY SSL CERTIFICATE
echo -e "\n${GREEN}>>> Waiting for Let's Encrypt Certificate issuance...${NC}"
echo "Checking domain: $DOMAIN"
echo "This may take up to 60-90 seconds."

MAX_CHECKS=30
CHECK_COUNT=0
CERT_READY=0

while [ $CHECK_COUNT -lt $MAX_CHECKS ]; do
    # Check the issuer of the certificate
    # -k allows curl to connect even if insecure, -v shows handshake
    ISSUER=$(curl -k -v "https://$DOMAIN" 2>&1 | grep "issuer:" | head -n 1)
    
    if [[ "$ISSUER" == *"Let's Encrypt"* ]]; then
        echo -e "\n${GREEN}>>> SSL Certificate Verified! Issuer: Let's Encrypt${NC}"
        CERT_READY=1
        break
    elif [[ "$ISSUER" == *"Traefik"* ]]; then
         echo -ne "${YELLOW}.${NC}" # Still default cert
    else
         echo -ne "${YELLOW}?${NC}" # Connection refused or other error
    fi
    
    sleep 5
    CHECK_COUNT=$((CHECK_COUNT+1))
done

if [ $CERT_READY -eq 0 ]; then
    echo -e "\n${YELLOW}WARNING: SSL Verification timed out.${NC}"
    echo "The certificate might still be issuing in the background."
    echo "Check logs with: kubectl logs -f -n kube-system -l app.kubernetes.io/name=traefik"
else
    echo -e "${GREEN}>>> Deployment successful! Your node is ready at https://$DOMAIN${NC}"
fi