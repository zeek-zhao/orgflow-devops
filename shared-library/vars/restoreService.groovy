// CONFIRM gates the destructive restore, including selection of the latest backup.
def call(Map cfg = [:]) {
    if (cfg.confirm != 'YES') {
        error('restoreService: CONFIRM 必须等于 YES')
    }
    def service = cfg.service ?: error('restoreService: service 必填')
    def file = cfg.backupFile ?: ''
    if (!(service in ['jenkins', 'nexus', 'ldap'])) {
        error('restoreService: 不支持的 service')
    }
    if (file && !(file ==~ /[A-Za-z0-9_.\/ -]+\.tgz/)) {
        error('restoreService: BACKUP_FILE 必须是合法的 .tgz 路径')
    }
    withEnv(["RESTORE_SERVICE=${service}", "RESTORE_FILE=${file}"]) {
        sh '''
            set +x
            set -eu
            file="$RESTORE_FILE"
            if [ -z "$file" ]; then
                file="$(python3 -c '
import os
from pathlib import Path
import sys
directory = Path(os.environ.get("BACKUP_DIR", "./out/backups"))
files = [p for p in directory.glob(os.environ["RESTORE_SERVICE"] + "-*.tgz") if p.is_file()]
if not files:
    sys.exit("没有该服务的备份包")
print(max(files, key=lambda p: (p.stat().st_mtime_ns, p.name)))
')"
            fi
            bash scripts/restore.sh --service "$RESTORE_SERVICE" --file "$file" --force
        '''
    }
}
