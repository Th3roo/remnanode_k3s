#!/bin/bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# --- 0. ПРОВЕРКИ ---
if [ ! -f secrets.yaml ]; then
    echo -e "${RED}ERROR: secrets.yaml not found!${NC}"
    exit 1
fi

EMAIL=$(grep 'email:' secrets.yaml | awk '{print $2}' | tr -d '"')
DOMAIN=$(grep 'domain:' secrets.yaml | awk '{print $2}' | tr -d '"')

if [ -z "$EMAIL" ] || [ -z "$DOMAIN" ]; then
    echo -e "${RED}ERROR: Email or Domain missing in secrets.yaml${NC}"
    exit 1
fi

# --- 1. УСТАНОВКА K3S ---
if ! command -v k3s &> /dev/null; then
    echo -e "${GREEN}>>> Installing K3s (Fresh Install)...${NC}"
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--kube-apiserver-arg service-node-port-range=1-65535 --write-kubeconfig-mode 644" sh -
    echo "Waiting for K3s node readiness..."
    sleep 20
else
    echo -e "${GREEN}>>> K3s already installed.${NC}"
fi

# Настройка конфига
if [ -f /etc/rancher/k3s/k3s.yaml ]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    mkdir -p ~/.kube
    cp /etc/rancher/k3s/k3s.yaml ~/.kube/config 2>/dev/null || true
    chmod 600 ~/.kube/config 2>/dev/null || true
else
    echo -e "${RED}CRITICAL: K3s config not found!${NC}"
    exit 1
fi

# --- 2. УСТАНОВКА HELM ---
if ! command -v helm &> /dev/null; then
    echo -e "${GREEN}>>> Installing Helm...${NC}"
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# --- 3. НАСТРОЙКА TRAEFIK (SSL) ---
echo -e "\n${GREEN}>>> Configuring Traefik SSL (ACME)...${NC}"

# Создаем секрет с почтой
kubectl create secret generic traefik-acme-secret \
  --from-literal=email=$EMAIL \
  --namespace kube-system \
  --dry-run=client -o yaml | kubectl apply -f -

# Применяем конфиг HelmChartConfig
kubectl apply -f configs/traefik-config.yaml

echo -e "${GREEN}>>> Waiting for K3s to process Traefik config...${NC}"

# Ждем пока K3s создаст деплоймент Traefik (на чистом сервере это не мгновенно)
MAX_LOOPS=60
LOOP=0
TRAEFIK_DEPLOY=""

while [ $LOOP -lt $MAX_LOOPS ]; do
    TRAEFIK_DEPLOY=$(kubectl get deploy -n kube-system -l app.kubernetes.io/name=traefik -o name | head -n 1)
    if [ ! -z "$TRAEFIK_DEPLOY" ]; then
        echo "Found: $TRAEFIK_DEPLOY"
        break
    fi
    echo -n "."
    sleep 2
    LOOP=$((LOOP+1))
done

if [ -z "$TRAEFIK_DEPLOY" ]; then
    echo -e "\n${RED}ERROR: Traefik deployment never appeared.${NC}"
    exit 1
fi

# Ждем завершения джобы Helm (важно, чтобы конфиг реально применился перед рестартом)
echo "Waiting for Helm Install Job..."
kubectl wait --for=condition=complete --timeout=120s job -n kube-system -l app.kubernetes.io/name=traefik-install 2>/dev/null || true
sleep 5

# --- 4. ПРИНУДИТЕЛЬНЫЙ РЕСТАРТ TRAEFIK ---
echo -e "\n${GREEN}>>> Forcing Traefik Restart (Applying ACME)...${NC}"
kubectl rollout restart $TRAEFIK_DEPLOY -n kube-system

echo "Waiting for Traefik to be ready..."
kubectl rollout status $TRAEFIK_DEPLOY -n kube-system --timeout=180s

# Даем время на внутреннюю инициализацию ACME (чтобы не пропустить создание сертификата)
echo -e "${YELLOW}>>> Pausing 15s to allow ACME engine to start...${NC}"
sleep 15

# --- 5. ДЕПЛОЙ ПРИЛОЖЕНИЯ ---
echo -e "\n${GREEN}>>> Deploying RemnaNode...${NC}"

# Удаляем старое, если было (для чистоты эксперимента)
helm uninstall remnanode -n remnanode 2>/dev/null || true
sleep 3

helm upgrade --install remnanode ./charts/remnanode \
  --namespace remnanode \
  --create-namespace \
  -f secrets.yaml

# --- 6. ПРОВЕРКА СЕРТИФИКАТА ---
echo -e "\n${GREEN}>>> Verifying SSL for $DOMAIN...${NC}"

MAX_CHECKS=20
CHECK=0

while [ $CHECK -lt $MAX_CHECKS ]; do
    ISSUER=$(curl -k -v --connect-timeout 5 "https://$DOMAIN" 2>&1 | grep "issuer:" | head -n 1)
    
    if [[ "$ISSUER" == *"Let's Encrypt"* ]]; then
        echo -e "\n${GREEN}SUCCESS! Issuer: Let's Encrypt${NC}"
        echo "Deployment Complete."
        exit 0
    fi
    
    echo -n "."
    sleep 5
    CHECK=$((CHECK+1))
done

echo -e "\n${YELLOW}WARNING: Still showing default cert. It usually takes ~60s to issue.${NC}"
echo "Check logs: kubectl logs -f -n kube-system -l app.kubernetes.io/name=traefik"