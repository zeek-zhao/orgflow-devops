#!/usr/bin/env python3
"""生成「声明式」SBOM（SPDX 2.3 JSON）。

为什么不是「扫出来的」SBOM
-------------------------
syft / trivy 这类工具要先把镜像拉到本地再逐文件解析，代价是几十 GB 与十几分钟，
放进 CI 不现实（本项目 CI 额度本就紧张）。这里改为**声明式**：

    镜像清单 ← docker-compose.ghcr.yml + scripts/nexus-deploy.sh（唯一真源，带 digest）
    许可证   ← 人工核对后固定在 DECLARED（依据见 public/THIRD_PARTY_NOTICES.md）

所以本文件回答的是「我们对外分发了什么、每个东西声明什么许可证」，
而不是「镜像里每一个文件的许可证」。前者是合规义务，后者是取证深度，两者不混。

用法：
    gen-sbom.py [输出路径]       默认 out/sbom.spdx.json
"""
import json
import os
import re
import sys
import uuid
from datetime import datetime, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 组件 → (声明许可证, 上游地址)。键是镜像名最后一段（去掉 mirror- 前缀后的本项目名）
DECLARED = {
    "caddy": ("Apache-2.0", "https://github.com/caddyserver/caddy"),
    "openldap": ("MIT AND LicenseRef-OpenLDAP-2.8", "https://github.com/osixia/docker-openldap"),
    "phpldapadmin": ("MIT AND GPL-2.0-only", "https://github.com/osixia/docker-phpldapadmin"),
    "dex": ("Apache-2.0", "https://github.com/dexidp/dex"),
    "oauth2-proxy": ("MIT", "https://github.com/oauth2-proxy/oauth2-proxy"),
    "nexus": ("EPL-1.0", "https://github.com/sonatype/nexus-public"),
    "homepage": ("GPL-3.0-only", "https://github.com/gethomepage/homepage"),
    "jenkins": ("MIT", "https://github.com/jenkinsci/jenkins"),
    "jenkins-agent": ("MIT", "https://github.com/jenkinsci/docker-ssh-agent"),
    "router": ("Apache-2.0", "https://github.com/zeek-zhao/orgflow-devops"),
    "jjb": ("Apache-2.0", "https://github.com/openstack-infra/jenkins-job-builder"),
    "dnsmasq": ("GPL-2.0-only", "https://thekelleys.org.uk/dnsmasq/doc.html"),
    "m0-test": ("Apache-2.0", "https://github.com/zeek-zhao/orgflow-devops"),
}


def collect_images():
    """从 compose 与 nexus 部署脚本取出 (引用, digest)。"""
    found = {}
    compose = os.path.join(ROOT, "docker-compose.ghcr.yml")
    if os.path.exists(compose):
        for line in open(compose, encoding="utf-8"):
            m = re.match(r"\s*image:\s*(\S+@sha256:[0-9a-f]{64})\s*$", line)
            if m:
                ref = m.group(1)
                found[ref.split("@")[0]] = ref
    nexus = os.path.join(ROOT, "scripts/nexus-deploy.sh")
    if os.path.exists(nexus):
        for line in open(nexus, encoding="utf-8"):
            m = re.search(r"(ghcr\.io/\S+@sha256:[0-9a-f]{64})", line)
            if m:
                found[m.group(1).split("@")[0]] = m.group(1)
    return sorted(found.values())


def component_key(ref):
    name = ref.split("@")[0].rsplit("/", 1)[-1].split(":")[0]
    return name[7:] if name.startswith("mirror-") else name


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "out/sbom.spdx.json")
    refs = collect_images()
    if not refs:
        print("没有取到任何镜像引用，SBOM 未生成", file=sys.stderr)
        return 1

    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    packages = []
    for i, ref in enumerate(refs, 1):
        name, _, digest = ref.partition("@")
        key = component_key(ref)
        lic, upstream = DECLARED.get(key, ("NOASSERTION", "NOASSERTION"))
        packages.append({
            "SPDXID": f"SPDXRef-Image-{i}",
            "name": name,
            "versionInfo": name.rsplit(":", 1)[-1] if ":" in name else "unknown",
            "downloadLocation": f"https://{name}",
            "filesAnalyzed": False,
            "licenseConcluded": lic,
            "licenseDeclared": lic,
            "copyrightText": "NOASSERTION",
            "checksums": [{"algorithm": "SHA256", "checksumValue": digest.split(":", 1)[1]}],
            "externalRefs": [{
                "referenceCategory": "PACKAGE-MANAGER",
                "referenceType": "purl",
                "referenceLocator": f"pkg:oci/{name.rsplit('/', 1)[-1].split(':')[0]}@{digest}",
            }],
            "comment": f"上游: {upstream}；许可证依据见 THIRD_PARTY_NOTICES.md",
        })

    doc = {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": "orgflow-devops-declared",
        "documentNamespace": f"https://github.com/zeek-zhao/orgflow-devops/sbom/{uuid.uuid4()}",
        "creationInfo": {
            "created": now,
            "creators": ["Tool: scripts/gen-sbom.py", "Organization: zeek-zhao"],
            "comment": "声明式 SBOM：组件取自 compose/部署脚本的 digest，许可证取自人工核对表；不做文件级扫描。",
        },
        "packages": packages,
        "relationships": [{
            "spdxElementId": "SPDXRef-DOCUMENT",
            "relationshipType": "DESCRIBES",
            "relatedSpdxElement": p["SPDXID"],
        } for p in packages],
    }

    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    print(f"✓ SBOM: {out}（{len(packages)} 个分发镜像）")
    unknown = [p["name"] for p in packages if p["licenseDeclared"] == "NOASSERTION"]
    if unknown:
        print("  未声明许可证: " + ", ".join(unknown), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
