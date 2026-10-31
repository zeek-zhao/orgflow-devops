set -euo pipefail
cd "$HOME/workbuddy/orgflow-devops"

TS=$(date +%Y%m%d-%H%M%S)
cp .env ".env.bak-$TS"
echo "备份: .env.bak-$TS"
git rev-parse --short HEAD > ".git-sha-before-$TS"
echo "旧 SHA: $(cat .git-sha-before-$TS)"

git fetch -q origin
echo "=== reset 前状态 ==="
git status -sb | head -1

git reset --hard origin/main
echo "=== reset 后 ==="
git log --oneline -1
echo "工作区: $(git status --porcelain | wc -l) 个改动"
