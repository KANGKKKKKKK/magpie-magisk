# 发布、签名与管理器更新

适用于包含本发布工作流的新版本。上游 Magpie 本体与模块 ZIP 各有独立的信任链：本体安装器验证 HTTPS 和清单里给出的版本、大小、SHA-256，**不等于独立验证上游 GPG 签名**；以下流程验证的是本仓库分发的 Root 模块 ZIP。

## 首次启用：仓库管理员必须先配置

1. 保护 `main`：要求审核和同一提交的 `ci`，限制直接推送/强推；保护 `v*` tag 的创建、移动和删除，只允许发布维护者从审核过的 `main` 提交创建。GitHub 的 tag 运行会读取该 tag 自己的 YAML。**环境审批和下面的 SHA 比对不能替代仓库的分支/tag 规则，也不能把工作流自己变成一个外部信任根。**
2. 建立三个 GitHub Actions Environment：`magpie-signing`、`magpie-publish`、`magpie-update-channel`。分别设置所需审批、限制适用 ref（签名仅发布 tag，其余允许发布 tag 与 `main`）、关闭 self-review 和管理员 bypass（以仓库方案支持的设置为准）。限制未审批的 workflow 不可接触部署环境，并检查仓库允许的 Actions 和 runner。不要给构建 job 增加 secrets 或写权限。
3. 三个 Environment 都配置变量 `MAGPIE_RELEASE_POLICY_SHA`，指向 **已审核、已在受保护 `main` 上的完整 40 位提交 SHA**，其中有本 `release.yml` 和对应 `scripts/ci`。工作流在特权 runner 上检出这份策略，不检出候选代码供执行；候选发布树只按 Commit SHA 读 Git blobs。策略有调整时，先审核、合入 `main`，再由管理员更新策略 SHA。触发的工作流与已批准策略版本不一致时失败关闭。
4. 将**现有**正式签名密钥的 `MAGPIE_KEYSTORE_B64` 和 `MAGPIE_KS_PASS` 仅存放于 `magpie-signing`。确认迁移后移除同名仓库级/组织级 secrets；不要新生成一把替换已发布 APK 的 key。可信证书的公开 SHA-256 保留在 `scripts/ci/tile-cert-sha256.txt`。两个发布环境都不持有 APK 私钥。另在 `magpie-publish` 配置 `MAGPIE_RELEASE_SETTINGS_TOKEN`：只允许本仓库 `Administration: read` 的细粒度凭据（短有效期），只用来查询 [不可变发布设置](https://docs.github.com/en/rest/repos/repos#check-if-immutable-releases-are-enabled-for-a-repository)。不要复用有仓库写权或组织管理权限的令牌。构建、签名、只读恢复和更新 PR job 不接收它。
5. 启用 **Immutable releases**（创建新发布前启用；不会让历史发布自动变为不可变），并把 Actions artifact 的仓库保留上限设为至少 35 天，允许每段交接覆盖各自的审批窗口；并确认本仓库允许 GitHub Actions 提交更新通道 PR。更新 job 不直接推 `main`，即便要求额外审批也不要绕过。若不能让 bot 提 PR，可留空工作流的同步选项并用常规审核流程手动提出同样的更新。

仓库内的权限和职责是：只读规划/无钥构建 → 独立签名（无 `contents: write`、无 OIDC）→ 独立验真发布（无 APK 私钥）→ 可选的更新通道 PR。手动草稿定稿不拿 OIDC/证明写权；公开恢复只拿读取权限。前两次 artifact 交接固定当前 run、attempt、目标 SHA、artifact ID 和摘要，严格校验文件名和内容上限，不在特权 runner 执行候选脚本或 artifact。若重跑正式构建，选择 **Re-run all jobs**，不会捡旧 attempt 的同名产物。

## 发布与恢复

- 正式版：更新 `module.prop` 的版本和递增 code（磁贴 runtime 改动也递增独立 `versionCode`），在 `main` 合入并确认精确 SHA 的 CI 为绿色。创建同名 annotated tag 并推送，按规则审批签名和公开发布。工作流短时间有界等待目标 CI，不接受其他提交的绿灯。
- 手动新建或预发布：`release.yml` 从**目标 tag ref**运行 `mode=build`（默认），如需预发布设置 `prerelease=true`。手动 `tag` 输入只能留空或等于触发 ref。不要从 `main` 构建带 tag provenance 的产物：只 checkout 到 tag 并不会改变 OIDC 的事件 ref。如 `v1.2.7-rc.1` 的带后缀 tag 不会自动构建；先推送同名 annotated tag，随后手动 dispatch 并选择预发布。正式版使用不带后缀的 tag。
- 草稿已上传但未公开：从 `main` 选择 `mode=finalize`，传入原 tag。不重编、不覆盖已有资产；验证三件资产和原始 tag 证明，再按草稿原有的 stable/prerelease 属性发布。
- 已公开不可变发布需复核，或正式版的更新索引尚未合入：从 `main` 选 `mode=recover`，传入原 tag。不重签或覆盖发布，只读复核资产；仅正式版可由独立更新 job 提 `update.json` PR。同一 tag 和 ZIP 摘要复用分支，只补中断的步骤，不强推。旧发布如果缺少新清单、证明或不可变状态，不能走该自动恢复路径。已经有同版更新 PR 时，优先检查/合并已有的，不重复提。
- 发布端按 Release ID / asset ID 回读 ZIP、`SHA256SUMS` 和 Sigstore bundle 并核对摘要，验 APK 的既有证书、源码清单、tag、提交及签名工作流；公开草稿前检查仓库已启用不可变发布；无法确认时留在草稿。公开后再次核对三个下载地址；如果动作已公开但公共验证暂时失败，可从 `main` 走只读恢复，不能直接推进索引。Release 能公开不表示更新通道已经变更；以受保护 `main` 上 `update.json` 的最终合入为准。

## 合并前可验证什么

`sh tests/run-all.sh` 在无正式密钥环境中运行 Shell、JVM、Python 和 WebUI 回归，并核对同一轮的计数。CI 再用一次性证书真实构建磁贴 APK 和模块 ZIP，核对签名、SDK、包内源码与权限；还会验证复用同一 APK 能产出相同 ZIP，且签名不符时不覆盖已有文件。这不是对正式证书的签名授权，也不是设备刷入测试。只有受保护发布流程产出的资产才是正式版；不要分发这些临时证书构建的包。

## 用户侧验真

取发布说明中写明的仓库、tag 和源码 commit，下载三个文件。先核对 `SHA256SUMS`，再按该版 Release 的 `gh attestation verify ... --bundle ... --source-ref ... --source-digest ... --signer-workflow ... --signer-digest ...` 说明验证 ZIP。APK 证书只覆盖 APK，不覆盖刷机包内 Root 脚本；Magisk、KernelSU、APatch 是否在刷入前执行整个 ZIP 的签名验真，不能由本仓库工作流保证。管理器不提供证明验证时，请先用独立工具核验再安装。
