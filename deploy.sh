#!/bin/bash
set -e

GREEN='\033[0;32m'
NC='\033[0m'

# Проверка наличия файла секретов
if [ ! -f secrets.yaml ]; then
    echo "ОШИБКА: Файл secrets.yaml не найден!"
    echo "Скопируйте secrets.example.yaml в secrets.yaml и заполните данные."
    exit 1
fi

# 1. Установка K3s (если нет)
if ! command -v k3s &> /dev/null; then
    echo -e "${GREEN}>>> Установка K3s...${NC}"
    curl -sfL https://get.k3s.io | sh -
    
    # Ждем пока K3s проснется
    echo "Ожидание готовности кластера..."
    sleep 20
    
    # Настройка прав для kubectl
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    chmod 644 /etc/rancher/k3s/k3s.yaml
else
    echo -e "${GREEN}>>> K3s уже установлен.${NC}"
fi

# 2. Установка Helm (если нет)
if ! command -v helm &> /dev/null; then
    echo -e "${GREEN}>>> Установка Helm...${NC}"
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# 3. Настройка Traefik (ACME Email)
# Вытаскиваем email из secrets.yaml для конфига кластера
EMAIL=$(grep 'email:' secrets.yaml | awk '{print $2}' | tr -d '"')
echo -e "${GREEN}>>> Настройка SSL для $EMAIL...${NC}"

# Подставляем email в конфиг Traefik и применяем
sed "s/YOUR_EMAIL_PLACEHOLDER/$EMAIL/" configs/traefik-config.yaml | kubectl apply -f -

# 4. Деплой приложения
echo -e "${GREEN}>>> Деплой RemnaNode через Helm...${NC}"

# Обновляем зависимости (если будут) и деплоим
helm upgrade --install remnanode ./charts/remnanode \
  --namespace remnanode \
  --create-namespace \
  -f secrets.yaml

echo -e "${GREEN}>>> Успешно! Статус подов:${NC}"
kubectl get pods -n remnanode