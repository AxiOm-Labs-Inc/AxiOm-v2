#!/usr/bin/env bash
# Проверка дерева перед публикацией в ПУБЛИЧНЫЙ репозиторий AxiOm-v2.
#
# Публично можно то, что показывает, что функция существует. Нельзя то, что
# показывает, как устроен Телемост, и всё приватное про сборку. 04.09.2026
# merge приватной ветки на сутки выложил в публичный репозиторий всю папку
# wbstream_tunnel/ — этот скрипт ловит ровно такое.
#
#   scripts/check_public_tree.sh [ref]     # по умолчанию HEAD
#
# Запускать на коммите, который собираетесь пушить в публичный, ДО push.
# Код возврата 1 — публиковать нельзя.
set -euo pipefail

REF=${1:-HEAD}
cd "$(dirname "$0")/.."

# Пути, которых не должно быть в публичном дереве вообще.
FORBIDDEN_PATHS='^(lib/features/wbstream_tunnel/|android/app/src/main/jniLibs/|android/app/relay\.version$|.*\.so$|.*/TunnelMethodHandler\.kt$|.*/TunnelRelayController\.kt$|.*/core_owner\.dart$|.*/connect_lock_shield\.dart$|docs/(ONBOARDING|REBRANDING|RELEASE_NOTES_FORMAT|COMMIT_FORMAT|BUILD_AND_RELEASE|PUBLISHING)\.md$|scripts/(build_android\.sh|build_windows\.ps1|verify_apk\.py|check_public_tree\.sh)$|\.env$|android/key\.properties$|.*\.(jks|keystore)$)'

# Слова, которые выдают механику, в содержимом любых файлов.
# LICENSE.md исключён: в §8 сказано лишь, что модули могут вырезаться из публичного кода.
FORBIDDEN_WORDS='wbstream|librelay|TunnelRelay|TunnelMethod|stream\.wb\.ru|yadi\.sk|tmSecret|tm_secret|core_owner|connect_lock_shield|whitelist-bypass|axiomtm'

bad=0

paths=$(git ls-tree -r --name-only "$REF" | grep -E "$FORBIDDEN_PATHS" || true)
if [ -n "$paths" ]; then
  echo "✗ Файлы, которым не место в публичном репозитории:"
  echo "$paths" | sed 's/^/    /'
  bad=1
fi

words=$(git grep -n -i -E "$FORBIDDEN_WORDS" "$REF" -- . ':!LICENSE.md' ':!*.lock' 2>/dev/null | cut -c1-160 || true)
if [ -n "$words" ]; then
  echo "✗ Упоминания механики Телемоста:"
  echo "$words" | sed 's/^/    /' | head -40
  bad=1
fi

if [ $bad -ne 0 ]; then
  echo
  echo "Публиковать $REF нельзя. Публичное дерево набирается переносом отдельных"
  echo "файлов, а не merge приватной ветки — см. docs/PUBLISHING.md."
  exit 1
fi
echo "✓ $REF можно публиковать: запретных файлов и упоминаний нет"
