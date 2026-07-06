# Деплой «Веракс» в кластер (демо-контур)

Веракс разворачивается в **тот же Timeweb-кластер, что и aerolist** (общий
nginx-ingress, cert-manager `letsencrypt`, один LB в TCP-passthrough на все
домены). Автодеплой — GitHub Actions (`.github/workflows/deploy.yml`):
тег `v*` → тесты → сборка образов в Docker Hub → `helm upgrade` в namespace `veraks`.

Домены: **veraks.ru** (фронт), **api.veraks.ru** (бэкенд), **esia.veraks.ru**
(мок-«Госуслуги»). TLS на все три — Let's Encrypt автоматически (cert-manager).

> Это демо-контур на моках (mock-ЕСИА + `local://`-платежи) — чтобы показать
> провайдерам ЕСИА/платёжного шлюза работающий сайт и ссылки на опубликованные
> юрдокументы (`/legal`). Перед боевым запуском (реальная ЕСИА + деньги) вынести
> в отдельный контур — см. `../audit/04-human-playbooks.md` §6.

## Разовая настройка (по шагам)

### 1. Ёмкость воркера (Terraform, репозиторий aerolist)
Веракс добавляет ~9 подов (свои Postgres/Redis/воркер/2 приложения). Поднять RAM
воркера, чтобы не конкурировать с aerolist за память:
```bash
# aerolist/infra/terraform/envs/prod/terraform.tfvars: worker_ram_mb = 16384 (было 8192)
cd ~/Documents/aerolist/infra/terraform/envs/prod
terraform plan   # убедиться, что меняется только worker
terraform apply  # ВНИМАНИЕ: ресайз воркера = перезагрузка ноды
```
Альтернатива без ресайза — добавить второй worker-нод (модуль compute). LB IP
берётся здесь же: `terraform output` (или панель Timeweb).

### 2. Репозиторий на GitHub
Проект пока не под git. Инициализировать и запушить:
```bash
cd ~/Documents/orakul
git init && git add -A && git commit -m "veraks: initial"
git branch -M main
git remote add origin git@github.com:<you>/veraks.git
git push -u origin main
```

### 3. Секреты GitHub (Settings → Secrets and variables → Actions)
| Секрет | Значение |
|---|---|
| `KUBECONFIG` | base64 kubeconfig того же кластера (у aerolist уже есть: `infra/terraform/envs/prod/kubeconfig.base64`) |
| `DOCKERHUB_USERNAME`, `DOCKERHUB_PASSWORD` | доступ к Docker Hub `avvolob/*` |
| `VERAKS_SNILS_HMAC_KEY` | `openssl rand -hex 32` |
| `VERAKS_FIELD_ENCRYPTION_KEY` | `python -c "from cryptography.fernet import Fernet;print(Fernet.generate_key().decode())"` |
| `VERAKS_JWT_SECRET` | `openssl rand -hex 32` |
| `VERAKS_POSTGRES_PASSWORD` | любой стойкий пароль |
| `VERAKS_WEBHOOK_PAYMENT_SECRET`, `VERAKS_WEBHOOK_PAYOUT_SECRET` | любые НЕПУСТЫЕ (вне `local` валидатор конфига требует непустые; для мока — любые) |
| `VERAKS_GOCTOPUS_PASSWORD` | любой пароль |

### 4. DNS (у регистратора veraks.ru)
Три A-записи на IP балансировщика кластера (из шага 1):
```
veraks.ru        A   <LB_IP>
api.veraks.ru    A   <LB_IP>
esia.veraks.ru   A   <LB_IP>
```
(опц. `www.veraks.ru` CNAME `veraks.ru`.) Пропаганда DNS + выпуск Let's Encrypt —
несколько минут; cert-manager выпустит сертификаты по HTTP-01, когда домены
начнут резолвиться на LB.

### 5. Первый деплой (с демо-данными)
Первый раз — с сидом (создаёт демо-события/лидерборды/пользователей для показа).
`seed.py` делает TRUNCATE, поэтому на апгрейдах сид ВЫКЛючен по умолчанию.
```bash
# kubeconfig уже настроен (шаг 1)
helm upgrade --install veraks ./infra/helm/veraks \
  --namespace veraks --create-namespace \
  --set images.backend.tag=latest --set images.frontend.tag=latest --set images.mockEsia.tag=latest \
  --set seed.enabled=true \
  --set secrets.snilsHmacKey=... --set secrets.jwtSecret=... --set secrets.fieldEncryptionKey=... \
  --set secrets.postgresPassword=... --set secrets.webhookPaymentSecret=demo --set secrets.webhookPayoutSecret=demo \
  --set secrets.goctopusPassword=... --wait
```
(Образы `latest` должны быть уже собраны — либо один раз запустить workflow
вручную «Run workflow», либо запушить тег `v0.1.0`.)

## Дальнейшие деплои — автоматически
```bash
git tag v0.1.1 && git push origin v0.1.1
```
→ workflow гоняет тесты, собирает образы (SHA-тег), `helm upgrade` (миграции
`alembic upgrade head` идут pre-upgrade хуком; сид НЕ запускается).

## Проверка
```bash
kubectl -n veraks get pods,ingress,certificate
kubectl -n veraks get certificate   # READY=True у veraks-tls/-api-tls/-esia-tls
curl -sI https://veraks.ru | head -1
```
Демо-вход: veraks.ru → «Войти через Госуслуги» → мок на esia.veraks.ru
(учётки kalibr/mediana/baseline из `seed.py`). Юрдокументы: veraks.ru/legal.

## Замена мока на реальные интеграции (позже)
- **ЕСИА:** убрать `mock-esia`, прописать `ESIA_*` реального шлюза/интегратора
  (`audit/04-human-playbooks.md` §2), добавить PKCE.
- **Платежи:** реализовать `YookassaSubscriptionCheckoutGateway`/`...PayoutGateway`
  (сейчас `local://`), выставить реальные `WEBHOOK_*` (§1 плейбука).
- Тогда же — вынос в изолированный контур + managed-Postgres с бэкапами (§6).
