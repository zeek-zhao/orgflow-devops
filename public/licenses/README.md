# 第三方许可证全文

本目录存放本项目再分发的第三方组件所要求的**许可证副本**。
义务依据与组件对应关系见 [`../THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md)。

| 文件 | 许可证 | 取得来源 | 校验（sha256） |
|---|---|---|---|
| `Apache-2.0.txt` | Apache License 2.0 | https://www.apache.org/licenses/LICENSE-2.0.txt | `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30` |
| `GPL-2.0.txt` | GNU GPL v2.0 | https://www.gnu.org/licenses/old-licenses/gpl-2.0.txt | `edaef632cbb643e4e7a221717a6c441a4c1a7c918e6e4d56debc3d8739b233f6` |
| `GPL-3.0.txt` | GNU GPL v3.0 | https://www.gnu.org/licenses/gpl-3.0.txt | `3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986` |
| `EPL-1.0.txt` | Eclipse Public License 1.0 | https://raw.githubusercontent.com/sonatype/nexus-public/main/LICENSE.txt | `ed8d7a24769ac9d57d08769b5f8be27519dd8811d06b0995dbe8ca6714e96d08` |
| `MIT.txt` | MIT（上游原文，无版权行） | https://raw.githubusercontent.com/oauth2-proxy/oauth2-proxy/v7.6.0/LICENSE | `89807acf2309bd285f033404ee78581602f3cd9b819a16ac2f0e5f60ff4a473e` |
| `OpenLDAP-2.8.txt` | OpenLDAP Public License 2.8 | https://raw.githubusercontent.com/openldap/openldap/master/LICENSE | `310fe25c858a9515fc8c8d7d1f24a67c9496f84a91e0a0e41ea9975b1371e569` |

取得日期：2026-11-11。文本均为上游原文，未做任何删改（`MIT.txt` 上游文件本身就
不含版权行，属上游写法，非本项目遗漏）。

校验方式：

```bash
cd licenses && sha256sum *.txt   # 与上表逐项对照
```

> 说明：新增任何 copyleft 组件时，必须同时更新本目录、`THIRD_PARTY_NOTICES.md`
> 与 `scripts/gen-sbom.py` 的 `DECLARED` 表——三处不一致等于声明不可信。
