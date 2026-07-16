# Деплой «Веракс» в кластер (демо-контур)

Три репозитория в организации `veraks-ru`:
- **veraks-backend** — FastAPI + ARQ-воркор; свой workflow собирает образ `avvolob/veraks`.
- **veraks-web** — Next.js + мок-ЕСИА; собирает `avvolob/veraks-web` и `avvolob/veraks-mock-esia`.
- **veraks-infra** (этот репо) — Helm-чарт (`helm/veraks`) и workflow деплоя.

Разворачивается в **тот же Timeweb-кластер, что aerolist** (общий nginx-ingress,
cert-manager `letsencrypt`, один LB `188.225.24.225` в TCP-passthrough на все домены).
Домены: **veraks.ru** (фронт), **api.veraks.ru** (бэкенд), **esia.veraks.ru** (мок-ЕСИА);
TLS на все три — Let's Encrypt автоматически.

> Демо на моках (mock-ЕСИА + `local://`-платежи) — показать провайдерам работающий
> сайт и юрдокументы (`/legal`). Перед боевым запуском — отдельный контур
> (см. `../audit/04-human-playbooks.md`, если он у вас рядом).

## Разовая настройка

### 1. Ёмкость кластера — ✅ сделано
Воркер поднят до 16 ГБ (`terraform apply` уже применён, нода перезагружена).

### 2. Секреты GitHub — на уровне ОРГАНИЗАЦИИ `veraks-ru`
Settings организации → Secrets and variables → Actions → New organization secret
(один раз, доступны всем трём репо):

| Секрет | Значение / команда |
|---|---|
| `DOCKERHUB_USERNAME` | `avvolob` |
| `DOCKERHUB_PASSWORD` | access-token с hub.docker.com (Account → Security → New Access Token, Read/Write) |
| `KUBECONFIG` | `cat ~/Documents/aerolist/infra/terraform/envs/prod/kubeconfig.base64` |
| `VERAKS_SNILS_HMAC_KEY` | `openssl rand -hex 32` |
| `VERAKS_JWT_SECRET` | `openssl rand -hex 32` |
| `VERAKS_FIELD_ENCRYPTION_KEY` | `python -c "from cryptography.fernet import Fernet;print(Fernet.generate_key().decode())"` |
| `VERAKS_POSTGRES_PASSWORD` | `openssl rand -base64 24` |
| `VERAKS_WEBHOOK_PAYMENT_SECRET` | `openssl rand -hex 16` (любой непустой) |
| `VERAKS_WEBHOOK_PAYOUT_SECRET` | `openssl rand -hex 16` |
| `VERAKS_GOCTOPUS_PASSWORD` | `openssl rand -hex 16` |
| `VERAKS_TBANK_TERMINAL_KEY` | Terminal Key из кабинета ТБанк (эквайринг) |
| `VERAKS_TBANK_PASSWORD` | пароль терминала ТБанк |
| `VERAKS_JUMP_API_KEY` | Client-Key из ЛК Jump.Finance (Настройки → Интеграции → OpenAPI; показывается один раз) |

> Приватные `avvolob/veraks*` тянутся из кластера через `veraks-regcred` — его
> создаёт деплой-workflow из `DOCKERHUB_*` и привязывает к default-SA неймспейса.
> (Если сделаете эти Docker Hub-репозитории публичными — pull-секрет не нужен, но
> он безвреден.)

### 3. DNS (у регистратора veraks.ru) — три A-записи на LB
```
veraks.ru        A   188.225.24.225
api.veraks.ru    A   188.225.24.225
esia.veraks.ru   A   188.225.24.225
```
(опц. `www.veraks.ru CNAME veraks.ru`.) Как записи разрезолвятся на LB,
cert-manager выпустит Let's Encrypt по HTTP-01 (несколько минут).

## Первый деплой

1. **Собрать образы** — в каждом репо запустить workflow (Actions → Run workflow,
   или запушить тег `v0.1.0`):
   - `veraks-backend` → `avvolob/veraks:latest`
   - `veraks-web` → `avvolob/veraks-web:latest` + `avvolob/veraks-mock-esia:latest`
2. **Задеплоить** — в `veraks-infra` → Actions → **Deploy veraks** → Run workflow,
   галочка **seed = true** (создаст демо-события/лидерборды/пользователей).
   Дальнейшие деплои — тот же workflow **без seed**. Миграции (`alembic upgrade
   head`) применяет initContainer бэкенда при каждом старте — до приёма трафика;
   seed запускается только при `seed=true` (post-upgrade хук, делает TRUNCATE).

### Хранилище БД
Postgres — на **постоянном томе** (`postgres.persistence: true`,
`storageClassName: local-path`, 5Gi). В кластере установлен
[local-path-provisioner](https://github.com/rancher/local-path-provisioner)
(namespace `local-path-storage`, данные на ноде в `/opt/local-path-provisioner`).
Данные **переживают перезапуск пода и ноды**. Ограничение: том привязан к ноде
(hostPath) — при пересоздании/замене воркер-ноды данные теряются, бэкапов нет.

Эфемерный режим (без провижнера): `postgres.persistence: false` → `emptyDir`,
демо-данные восстанавливает seed.

Боевой контур позже — **managed-Postgres с бэкапами**, как у aerolist
(terraform-модуль `~/Documents/aerolist/infra/terraform/modules/postgres`,
`twc_database_cluster` + ежедневный `twc_database_backup_schedule`): создать
инстанс, вписать его `DATABASE_URL` в секрет и выключить in-cluster Postgres
(`postgres.enabled: false` / убрать из чарта). Требует TWC-токена и платный.

## Проверка
```bash
KC=~/Documents/aerolist/infra/terraform/envs/prod/kubeconfig.yaml
kubectl --kubeconfig $KC -n veraks get pods,ingress,certificate
kubectl --kubeconfig $KC -n veraks get certificate   # READY=True у трёх сертов
curl -sI https://veraks.ru | head -1
```
Демо-вход: veraks.ru → «Войти через Госуслуги» → мок на esia.veraks.ru
(учётки kalibr/mediana/baseline из seed). Юрдокументы: veraks.ru/legal.

## Замена мока на боевые интеграции (позже)
- **ЕСИА:** убрать mock-esia, прописать боевые `ESIA_*` (в `helm/veraks/values.yaml`
  → `env` + секрет), добавить PKCE.
- **Платежи:** реализовать YooKassa-шлюзы в бэкенде (сейчас `local://`), выставить
  реальные `WEBHOOK_*`.
- Тогда же — вынос в изолированный контур + managed-Postgres с бэкапами.
