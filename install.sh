#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
#  NODE SHIELD — установка одной командой
#
#    curl -fsSL https://raw.githubusercontent.com/qwexdesign/node-shield-install/main/install.sh | bash
#
#  Сам скрипт лежит в закрытом репозитории. Этот загрузчик входит в GitHub
#  «по коду»: показывает ссылку и короткий код, вы подтверждаете вход в браузере
#  на телефоне или компьютере — и он скачивает установщик из закрытого
#  репозитория. Токен живёт только в памяти этого процесса и нигде не сохраняется.
#  Доступ есть только у тех, кого владелец добавил в репозиторий.
#
#  Параметры передаются установщику:  ... | bash -s -- --version v2.10.0
#                                      ... | bash -s -- --no-run | --check
#  Свой токен вместо входа по коду:    GH_TOKEN=... (см. docs/ACCESS.md)
# ════════════════════════════════════════════════════════════════════════════
set -euo pipefail

CLIENT_ID=${NS_CLIENT_ID:-Ov23limtigmAUtslpVcP}   # публичный идентификатор приложения, не секрет
REPO=${NS_REPO:-qwexdesign/node-shield}
REF=${NS_INSTALLER_REF:-main}                     # откуда брать сам установщик
GH=https://github.com
API=https://api.github.com

if [[ -t 2 ]]; then G=$'\e[32m' Y=$'\e[33m' E=$'\e[31m' B=$'\e[1m' D=$'\e[2m' N=$'\e[0m'; else G="" Y="" E="" B="" D="" N=""; fi
say()  { printf '%s\n' "$*" >&2; }
ok()   { printf '%s✓%s %s\n' "$G" "$N" "$*" >&2; }
die()  { printf '%s✗%s %s\n' "$E" "$N" "$*" >&2; exit 1; }

for a in "$@"; do
  case $a in
    -h|--help)
      cat >&2 <<EOF
NODE SHIELD — установка одной командой

  curl -fsSL https://raw.githubusercontent.com/qwexdesign/node-shield-install/main/install.sh | bash
  ... | bash -s -- --version v2.10.0   конкретный релиз
  ... | bash -s -- --no-run            только поставить, меню не открывать
  ... | bash -s -- --check             какая версия стоит и какая последняя

Вход — через GitHub по коду, без токенов. Нужен доступ к репозиторию $REPO
(его выдаёт владелец).
EOF
      exit 0 ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Нужны права root. Запустите так:  curl -fsSL …/install.sh | sudo bash"
command -v curl >/dev/null 2>&1 || {
  say "Ставлю curl…"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates >/dev/null \
    || die "Не удалось поставить curl"
}

json_get() {             # json_get КЛЮЧ — строковое или числовое поле из плоского JSON на stdin
  sed -n -E "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"?([^\",}]*)\"?.*/\\1/p" | head -n1
}

post() {                 # post URL ДАННЫЕ — POST формы, ответ JSON
  curl -sS --connect-timeout 10 --max-time 30 -X POST -H "Accept: application/json" "$1" -d "$2"
}

# ── вход по коду (OAuth device flow) ───────────────────────────────────────
login() {
  local r dc uc uri interval expires waited=0 err
  r=$(post "$GH/login/device/code" "client_id=$CLIENT_ID&scope=repo") || die "Нет связи с github.com"
  err=$(json_get error <<<"$r")
  [[ -z $err ]] || die "GitHub отказал во входе по коду ($err) — сообщите владельцу репозитория"
  dc=$(json_get device_code <<<"$r"); uc=$(json_get user_code <<<"$r")
  uri=$(json_get verification_uri <<<"$r"); interval=$(json_get interval <<<"$r"); expires=$(json_get expires_in <<<"$r")
  [[ -n $dc && -n $uc ]] || die "GitHub прислал непонятный ответ на запрос кода"
  interval=${interval:-5} expires=${expires:-900}

  say ""
  say "  ${B}Вход в GitHub${N}"
  say "  1. Откройте на телефоне или компьютере:  ${B}${uri:-$GH/login/device}${N}"
  say "  2. Введите код:                          ${B}${G}$uc${N}"
  say "  3. Нажмите «Authorize» — дальше всё само."
  say "  ${D}Код действует $(( expires / 60 )) мин. Ctrl+C — отмена.${N}"
  say ""

  while (( waited < expires )); do
    sleep "$interval"; waited=$(( waited + interval ))
    r=$(post "$GH/login/oauth/access_token" \
      "client_id=$CLIENT_ID&device_code=$dc&grant_type=urn:ietf:params:oauth:grant-type:device_code") || continue
    TOKEN=$(json_get access_token <<<"$r")
    [[ -n $TOKEN ]] && { ok "Вход подтверждён"; return 0; }
    case $(json_get error <<<"$r") in
      authorization_pending) ;;
      slow_down) interval=$(( interval + 5 )) ;;
      expired_token) die "Код истёк — запустите команду ещё раз" ;;
      access_denied) die "Вход отклонён в браузере" ;;
      *) die "GitHub ответил: $(json_get error_description <<<"$r")" ;;
    esac
  done
  die "Код истёк — запустите команду ещё раз"
}

TOKEN=${GH_TOKEN:-${GITHUB_TOKEN:-}}
[[ -n $TOKEN ]] || login

code=$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "$API/repos/$REPO") || die "Нет связи с api.github.com"
case $code in
  200) ;;
  401) die "GitHub не принял вход — запустите ещё раз" ;;
  404|403) die "У вашего аккаунта нет доступа к $REPO. Попросите владельца добавить вас и примите приглашение на github.com" ;;
  *) die "GitHub ответил кодом $code" ;;
esac

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"; unset TOKEN' EXIT
code=$(curl -sS -L -o "$tmp/install.sh" -w '%{http_code}' \
  -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github.raw" -H "X-GitHub-Api-Version: 2022-11-28" \
  "$API/repos/$REPO/contents/install.sh?ref=$REF") || die "Не удалось скачать установщик"
[[ $code == 200 ]] || die "Не удалось скачать установщик (код $code)"
grep -q 'NODE SHIELD' "$tmp/install.sh" && bash -n "$tmp/install.sh" || die "Скачанный установщик повреждён"

rc=0
GH_TOKEN=$TOKEN NS_REPO=$REPO bash "$tmp/install.sh" "$@" || rc=$?
unset TOKEN
if [[ -z ${GH_TOKEN:-}${GITHUB_TOKEN:-} ]]; then
  say "${D}Доступ установщику больше не нужен. Отозвать его можно здесь: $GH/settings/applications${N}"
fi
exit "$rc"
