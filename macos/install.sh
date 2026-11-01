#!/bin/bash
# Синергиум.Антиблок: установка проверенного выпуска 1.0.0.
# Снимает quarantine только с устанавливаемой копии приложения.
# Не меняет Gatekeeper, SIP, настройки сети или разрешения пользователя.
set -euo pipefail
umask 077

VERSION='1.0.0'
BUILD='32'
ZIP_URL='https://github.com/waseg-kz/sinergium-antiblock-releases/releases/download/macos/v1.0.0/Sinergium-Antiblock-1.0.0-macOS-universal.zip'
ZIP_SHA256='f6f785f2c0b0d6a636eefca387264d9be51d9c4e55ce29c03c679a274a805392'
MIN_OS='14.0'
APP_NAME='Синергиум.Антиблок.app'
BUNDLE_ID='local.macsignallab.diagnostic'
EXECUTABLE='MacSignalLab'
archive=''
destination=''
launch=1
work=''
stage=''
target=''
lock=''
lock_owned=0
backup_moved=0
committed=0

fail() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }
usage() {
  printf '%s\n' 'Установка Синергиум.Антиблок' \
    '  --archive PATH       Использовать уже скачанный ZIP этого выпуска' \
    '  --destination PATH   Установить в указанную папку' \
    '  --no-open            Не запускать приложение после установки'
}
cleanup() {
  result=$?
  trap - EXIT HUP INT TERM
  keep_stage=0
  if [[ "$backup_moved" == 1 && "$committed" == 0 ]]; then
    if [[ ! -e "$target" && ! -L "$target" ]] && /bin/mv "$stage/previous.app" "$target"; then
      printf '%s\n' 'Прежняя версия восстановлена.' >&2
    else
      keep_stage=1
      printf 'Прежняя версия сохранена: %s\n' "$stage/previous.app" >&2
    fi
  fi
  if [[ "$lock_owned" == 1 ]]; then /bin/rmdir "$lock" 2>/dev/null || true; fi
  if [[ -n "$stage" && "$keep_stage" == 0 ]]; then /bin/rm -rf "$stage"; fi
  if [[ -n "$work" ]]; then /bin/rm -rf "$work"; fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive) [[ $# -ge 2 ]] || fail 'После --archive нужен путь.'; archive="$2"; shift 2 ;;
    --destination) [[ $# -ge 2 ]] || fail 'После --destination нужен путь.'; destination="$2"; shift 2 ;;
    --no-open) launch=0; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Неизвестный параметр: $1" ;;
  esac
done

[[ "$(/usr/bin/uname -s)" == Darwin ]] || fail 'Установщик предназначен для macOS.'
[[ "$(/usr/bin/id -u)" != 0 ]] || fail 'Запускайте обычным пользователем, без sudo.'
system_version=$(/usr/bin/sw_vers -productVersion)
/usr/bin/awk -v old="$system_version" -v new="$MIN_OS" 'BEGIN { split(old,a,"."); split(new,b,"."); for(i=1;i<=3;i++) { if(a[i]+0>b[i]+0)exit 0; if(a[i]+0<b[i]+0)exit 1 } }' || fail "Нужна macOS ${MIN_OS} или новее."
case "$(/usr/bin/uname -m)" in arm64|x86_64) ;; *) fail 'Поддерживаются Apple Silicon и Intel.' ;; esac

work=$(/usr/bin/mktemp -d /private/tmp/antiblock-download.XXXXXX)
if [[ -n "$archive" ]]; then
  [[ -f "$archive" && ! -L "$archive" ]] || fail 'ZIP не найден или является символической ссылкой.'
  /bin/cp "$archive" "$work/package.zip"
else
  printf 'Скачиваю Синергиум.Антиблок %s…\n' "$VERSION"
  /usr/bin/curl --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --fail --location --retry 3 --connect-timeout 20 --max-time 180 \
    --silent --show-error --output "$work/package.zip" "$ZIP_URL" || fail 'Не удалось скачать приложение. Проверьте интернет и повторите.'
fi
actual=$(/usr/bin/shasum -a 256 "$work/package.zip")
actual=${actual%% *}
[[ "$actual" == "$ZIP_SHA256" ]] || fail 'Контрольная сумма ZIP не совпала. Установка отменена.'

/usr/bin/ditto -x -k "$work/package.zip" "$work/unpacked" || fail 'Не удалось распаковать ZIP.'
source_app="$work/unpacked/$APP_NAME"
[[ -d "$source_app" && ! -L "$source_app" ]] || fail 'В ZIP нет ожидаемого приложения.'
info="$source_app/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")" == "$BUNDLE_ID" ]] || fail 'Другое приложение в ZIP.'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info")" == "$EXECUTABLE" ]] || fail 'Неверный исполняемый файл.'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")" == "$VERSION" ]] || fail 'Версия приложения не совпала.'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info")" == "$BUILD" ]] || fail 'Номер сборки не совпал.'
/usr/bin/codesign --verify --deep --strict --all-architectures "$source_app" || fail 'Нарушена целостность подписи приложения.'

if [[ -z "$destination" ]]; then
  if [[ -e "/Applications/$APP_NAME" && -e "$HOME/Applications/$APP_NAME" ]]; then
    fail 'Найдены две установки. Укажите нужную папку через --destination.'
  elif [[ -e "$HOME/Applications/$APP_NAME" ]]; then
    destination="$HOME/Applications"
  elif [[ -e "/Applications/$APP_NAME" ]]; then
    destination='/Applications'
  elif [[ -w /Applications ]]; then
    destination='/Applications'
  else
    destination="$HOME/Applications"
  fi
fi
[[ "$destination" == /* ]] || fail 'Папку установки нужно указать полным путём.'
/bin/mkdir -p "$destination" || fail 'Не удалось создать папку установки.'
destination=$(cd -P "$destination" && pwd -P)
[[ -w "$destination" ]] || fail 'Нет прав на папку установки. Укажите свою папку через --destination.'
target="$destination/$APP_NAME"
[[ ! -L "$target" ]] || fail 'Путь приложения является символической ссылкой. Установка отменена.'
lock="$destination/.sinergium-antiblock-install.lock"
/bin/mkdir "$lock" 2>/dev/null || fail 'В этой папке уже идёт установка. Дождитесь её окончания.'
lock_owned=1

if [[ -e "$target" ]]; then
  [[ -d "$target" ]] || fail 'Путь приложения занят файлом.'
  old_info="$target/Contents/Info.plist"
  old_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$old_info" 2>/dev/null) || fail 'Не удалось проверить прежнее приложение.'
  [[ "$old_id" == "$BUNDLE_ID" ]] || fail 'Путь занят другим приложением. Оно не будет заменено.'
  old_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$old_info" 2>/dev/null) || fail 'Не удалось проверить номер установленной сборки.'
  [[ "$old_build" =~ ^[0-9]+([.][0-9]+){0,2}$ ]] || fail 'Неверный номер установленной сборки.'
  /usr/bin/awk -v old="$old_build" -v new="$BUILD" 'BEGIN { split(old,a,"."); split(new,b,"."); for(i=1;i<=3;i++) { if(a[i]+0>b[i]+0)exit 1; if(a[i]+0<b[i]+0)exit 0 } }' || fail 'Уже установлена более новая версия. Понижение отменено.'
fi
if pids=$(/usr/bin/pgrep -u "$(/usr/bin/id -u)" -x "$EXECUTABLE"); then
  for pid in $pids; do
    if files=$(/usr/sbin/lsof -a -p "$pid" -d txt -Fn 2>/dev/null); then
      if /usr/bin/grep -Fx "n$target/Contents/MacOS/$EXECUTABLE" <<< "$files" >/dev/null; then
        fail 'Завершите Антиблок через его меню и повторите установку.'
      fi
    elif kill -0 "$pid" 2>/dev/null; then
      fail 'Не удалось проверить запущенный Антиблок. Завершите его и повторите установку.'
    fi
  done
else
  code=$?
  [[ "$code" == 1 ]] || fail 'Не удалось проверить запущенное приложение.'
fi

stage=$(/usr/bin/mktemp -d "$destination/.antiblock-install.XXXXXX")
printf 'Устанавливаю %s в %s…\n' "$VERSION" "$destination"
/usr/bin/ditto --noqtn "$source_app" "$stage/new.app" || fail 'Не удалось подготовить приложение.'
# Пользователь запускает этот установщик для разрешения именно этой проверенной копии.
/usr/bin/xattr -dr com.apple.quarantine "$stage/new.app" || fail 'Не удалось снять карантин с устанавливаемой копии.'
/usr/bin/codesign --verify --deep --strict --all-architectures "$stage/new.app" || fail 'Проверка подготовленного приложения не пройдена.'
if [[ -e "$target" ]]; then
  /bin/mv "$target" "$stage/previous.app" || fail 'Не удалось переместить прежнюю версию.'
  backup_moved=1
fi
[[ ! -e "$target" && ! -L "$target" ]] || fail 'Папка приложения изменилась во время установки.'
/bin/mv "$stage/new.app" "$target" || fail 'Не удалось установить приложение.'
committed=1
printf 'Готово: %s\nНастройки и журнал IP сохранены.\n' "$target"
if [[ "$launch" == 1 ]]; then
  /usr/bin/open "$target" || printf '%s\n' 'Приложение установлено. Откройте его из папки установки.' >&2
fi
