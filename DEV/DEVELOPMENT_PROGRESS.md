# 开发进度整理

最后更新：2026-04-14

## 2026-04-14：Benchmark 独立 section 与全量执行记录

### 背景

本轮目标为两部分：

1. 将 benchmark 相关资产从分散位置收敛为独立 section，便于统一维护。
2. 基于 `ttapi` 服务商 endpoint 完成一次主模型 + ablation 的全量 benchmark 执行并沉淀结果。

### 实施内容

#### 1. 目录独立化（Section 化）

- 新建统一根目录：`benchmark/`
- 目录分层：
  - `benchmark/tools/`：runner 与 mock 测试
  - `benchmark/config/`：benchmark 与 participant 配置
  - `benchmark/prompts/`：baseline prompt 模板
  - `benchmark/fixtures/mock_openai/`：fixture 样例
  - `benchmark/runs/`：运行产物
  - `benchmark/reports/manuscript/`：可直接用于稿件的结果文件
- Make 与文档入口统一切换为 `benchmark/` 路径。

#### 2. 运行参数与执行

- 运行 ID：`full_ttapi_20260413_233845`
- Endpoint：`https://w.ciykj.cn/v1`
- participants：
  - `s2f-agent`
  - `gpt-4o`
  - `o3-mini`
  - `o3-mini-direct`
  - `o3-mini-catalog-only`
- suites：`routing` / `groundedness` / `task_success`
- seed：`7`
- timeout / retries：`300s / 5`

#### 3. 核心结果（overall micro / macro）

- `s2f-agent`: `100.00% / 100.00%`
- `gpt-4o`: `24.24% / 20.42%`
- `o3-mini`: `24.24% / 25.83%`
- `o3-mini-direct`: `0.00% / 0.00%`
- `o3-mini-catalog-only`: `15.15% / 10.00%`

### 产物与落地位置

- run 目录：`benchmark/runs/full_ttapi_20260413_233845/`
- manuscript latest：`benchmark/reports/manuscript/benchmark-results-latest.md`
- summary：`benchmark/reports/manuscript/benchmark-summary-full_ttapi_20260413_233845.csv`
- stats：`benchmark/reports/manuscript/benchmark-stats-full_ttapi_20260413_233845.json`

### 备注

- 本次运行中 baseline case record 均为 `error: null`，可用于稿件表格整理。
- 为控制仓库体积与历史噪声，提交阶段应避免将 `benchmark/runs` 与 `benchmark/reports` 纳入版本管理。

## 2026-04-07：Tutorials 与 Playbooks 合并重构落地

### 背景

根据已确认方案，执行“按任务聚合 + 一次性切换”：以 `playbooks/` 作为唯一入口，吸收原 `tutorials/` 的学习内容，并移除旧目录。

### 实施内容

#### 1. 目录与入口重构

- 新增统一入口：`playbooks/README.md`（学习路径与任务入口）。
- 新增通用学习页：
  - `playbooks/getting-started/README.md`
  - `playbooks/troubleshooting/README.md`
- 删除 `tutorials/` 目录及其 7 个历史文件（不保留兼容跳转壳）。

#### 2. 任务文档合并（5 个核心任务）

- 重构以下 playbook，统一为双视图结构：
  - `playbooks/variant-effect/README.md`
  - `playbooks/embedding/README.md`
  - `playbooks/track-prediction/README.md`
  - `playbooks/fine-tuning/README.md`
  - `playbooks/environment-setup/README.md`
- 每个任务页统一章节：
  - `Purpose / Use This When`
  - `Required Inputs (Canonical Keys)`
  - `Skill Selection Heuristics`
  - `Runbook (Minimal Reproducible Commands)`
  - `Learn (Step-by-step + checkpoints + common failures)`
  - `Clarify & Retry`

#### 3. 引用与校验链路联动

- 文档引用更新：
  - `README.md`：将 “Step-by-step tutorials” 改为 “Learning in playbooks” 并指向新路径。
  - `docs/scripts-reference.md`：学习入口改为 `playbooks/getting-started/README.md`。
- 冒烟测试更新：
  - `scripts/smoke_test.sh` 新增 `playbooks/getting-started/README.md` 与 `playbooks/troubleshooting/README.md` 的存在性检查。

#### 4. 接口兼容保持

- `scripts/run_agent.sh` 未改字段命名，继续输出 `playbook` 字段。
- 5 个任务仍返回 `playbooks/<task>/README.md` 路径，保持下游消费兼容。

### 验证结果

- 路径扫描：
  - 全仓不再引用 `tutorials/README.md` 与 `tutorials/01..06` 文件路径。
- 运行时回归：
  - 对 `variant-effect` / `embedding` / `track-prediction` / `fine-tuning` / `environment-setup` 执行 `run_agent.sh --format json`，`playbook` 字段均非空且路径正确。
- 冒烟回归：
  - `bash scripts/smoke_test.sh` 通过（含新增两个 playbook 检查项）。

## 2026-03-31：NTv3 BED 批量预测测试与 skill/agent 联动优化

### 背景

基于真实请求“使用 `case-study/track_prediction/bed/Test.interval.bed` 进行 NTv3 track prediction 批量预测，并输出到 `ntv3_results`”，对 `nucleotide-transformer-v3` skill、`run_agent.sh` 规划逻辑、输出契约与评测用例进行一次完整联动升级。

### 实施内容

#### 1. 真实执行测试（BED 批量）

- 输入：`case-study/track_prediction/bed/Test.interval.bed`（4 个区间）。
- 运行方式：逐区间执行 NTv3，失败区间单次 `--disable-xet` 重试。
- 输出目录：`case-study/track_prediction/ntv3_results`。
- 产物校验：
  - 4/4 区间均产出 `*_trackplot.png`、`*_result.json`、区间级 `ntv3_<chrom>_<start>_<end>.log`。
  - 结果 JSON 中 `species/assembly/chrom/start/end` 与 BED 输入一致。
  - 日志包含 `loading config/tokenizer/model from HF`、`saved plot`、`saved meta`。

#### 2. 新增 NTv3 BED 批量工具

- 新建：`skills/nucleotide-transformer-v3/scripts/run_track_prediction_bed_batch.py`。
- 能力：
  - 参数：`--bed/--model/--species/--assembly/--output-dir/--hf-token/--device/--dtype`。
  - 跳过空行与注释，支持文件末行无换行。
  - 每区间调用现有 `run_track_prediction.py`。
  - 每区间失败后自动重试一次 `--disable-xet`。
  - 继续执行后续区间，失败不阻断整批。
  - 汇总输出：`ntv3_bed_batch_summary.json`（`total/succeeded/failed` 与失败详情）。
- 退出语义：即使有部分失败，进程退出码固定 `0`（失败以 summary 表示）。

#### 3. agent 规划逻辑优化（`scripts/run_agent.sh`）

- 新增 BED 路径提取函数：支持从 query 中识别 `.bed` 文件路径。
- 扩展 NTv3 输出目录解析：支持 `case-study/...`、`output/...` 以及 `ntv3_results` 关键词路径。
- 新增 NTv3 BED fastpath：
  - 在 `task=track-prediction`、`primary_skill=nucleotide-transformer-v3` 且 `species/assembly + bed` 满足时，生成 `run_track_prediction_bed_batch.py` 执行步骤。
  - 生成批量预期产物：summary、batch log、`*_trackplot.png`、`*_result.json`、区间级 log。
- 单区间 fastpath 对齐：
  - `expected_outputs` 从 `*_meta.json` 改为 `*_result.json`。

#### 4. skill/contract/docs/eval 联动

- `skills/nucleotide-transformer-v3/skill.yaml`
  - `sequence-or-interval` 映射补充 `.bed/bed/file/path`。
  - 新增工具声明与 contract：`run_track_prediction_bed_batch.py`。
- `skills/nucleotide-transformer-v3/SKILL.md`
  - 新增 BED batch fastpath 命令模板与行为说明。
  - 验收口径统一为 `*_result.json`。
- `registry/output_contracts.yaml`、`docs/contracts.md`
  - track-prediction metadata 文案从 `track-prediction-metadata.json` 对齐为 `track-prediction-result.json`。
- `evals/task_success/cases.yaml`
  - 新增 `task_success_011`（NTv3 BED batch 用例）。
- `docs/evals.md`
  - 新增 BED batch task-success 示例。

### 验证结果

- 语法/编译：
  - `bash -n scripts/run_agent.sh` 通过。
  - `python -m py_compile skills/nucleotide-transformer-v3/scripts/run_track_prediction_bed_batch.py` 通过。
- 规划回归：
  - 单区间 query：`expected_outputs` 正确为 `*_result.json`。
  - BED query：`runnable_steps` 正确调用 `run_track_prediction_bed_batch.py`，并保留指定输出目录。
- 评测回归：
  - `bash scripts/validate_task_success.sh`：`11/11 passed`（含新增 `task_success_011`）。
  - `bash scripts/validate_input_contracts.sh`：通过。
  - `bash scripts/validate_skill_metadata.sh`：通过。
- 新脚本行为测试：
  - 无效 BED 用例：`failed_count>0` 且退出码 `0`。
  - 单区间真实 smoke：成功产出 `trackplot/result/summary`。

## 2026-03-30：AlphaGenome VCF 批量预测与 Skill 输入输出优化

### 背景

基于实际运行案例（`test_variant_df.csv` 与 `Test.geuvadis.vcf` 的多组织变异效应预测），对 `alphagenome-api` skill 的 VCF 输入支持和输出契约进行系统性优化。

### 实施内容

#### 1. `case-study/run_variant_df_effect.py`

- 新增多组织（8 tissues）预测支持，`TISSUE_DICT` 硬编码内置
- 输出列从单一 `mean_diff/log2fc` 改为每组织独立两列（共 16 列效应值）
- 完成 999/999 变异全部成功预测，输出 `variant_df_summary_tissues.tsv`

#### 2. `case-study/run_vcf_effect.py`

- 新增 VCF 批量预测脚本，支持标准 VCF 输入（CHROM 自动补 `chr`，POS 1-based）
- 多组织预测，输出含每组织 `{tissue}_mean_diff` / `{tissue}_log2fc`
- 完成 Test.geuvadis.vcf 的多组织预测，输出 `Test.geuvadis_tissues.tsv`

#### 3. `case-study/run_vcf_effect.py` 输入输出优化（用户确认需求后）

- **INFO 字段全量透传**：两遍扫描 VCF，动态收集所有 INFO key（31 个），按字母排序输出
- **Indel 支持**：移除 SNP-only 过滤，`genome.Variant` 直接传入多碱基 ref/alt；新增 `variant_type` 列（SNP/INS/DEL/MNP）
- **多 ALT 处理**：自动取第一个 ALT 等位基因
- **`--limit N`**：新增调试参数

#### 4. `skills/alphagenome-api/scripts/run_alphagenome_vcf_batch.py`（新建）

- 将 `case-study/run_vcf_effect.py` 提升为 skill 脚本
- 修复 `repo_root` 路径（从 `skills/alphagenome-api/scripts/` 正确回溯到仓库根）
- 新增 `--interval-width`（支持 16384/131072/524288/1048576，含合法性校验）
- 新增每 50 条进度日志
- **`TISSUE_DICT` 可配置化**：
  - `--tissues path/to/tissues.json` 或内联 JSON
  - 省略时触发交互确认提示（展示默认列表，用户输入 Y/n/路径）
  - `--non-interactive` 跳过提示直接使用默认值

#### 5. `registry/input_schema.yaml`

- 新增三个输入键：`vcf-input`、`vcf-info-passthrough`、`indel-handling`

#### 6. `skills/alphagenome-api/skill.yaml`

- `optional_inputs` 新增：`vcf-input`、`vcf-info-passthrough`、`indel-handling`
- `input_mappings` 新增对应条目
- `scripts` 节新增两个脚本注册：`run_alphagenome_predict_variant`、`run_alphagenome_vcf_batch`
- `constraints` 更新：支持 SNP 与 indel，INFO 字段透传，VCF POS 直接作为 1-based 坐标

#### 7. `registry/output_contracts.yaml`

- `variant-effect` 契约新增：
  - VCF 和 CSV 两类批量脚本的调用命令
  - 详细输出列结构（base + INFO passthrough + 8×tissue + metadata）
  - 8 个组织的 ontology 映射表
  - 新增 assumptions：indel 支持、INFO 透传、VCF POS 坐标约定

#### 8. `skills/alphagenome-api/SKILL.md`

- 新增 "Batch VCF Prediction" 章节，记录完整用法、参数说明、tissue config 格式、输出列结构

### 验证结果

- `run_alphagenome_vcf_batch.py` 语法通过（`py_compile OK`）
- smoke test（前 3 个变异）：3/3 成功，31 个 INFO key 正确透传，`variant_type` 列正常
- 输出列数：58 列（9 base + 31 INFO + 16 tissue + 3 metadata）
- `test_variant_df.csv`：999/999 成功，输出 `variant_df_summary_tissues.tsv`
- `Test.geuvadis.vcf`：smoke test 通过，完整批量运行已启动
EOF",
  "description": "Append to DEVELOPMENT_PROGRESS.md
## 2026-03-30：Skill Output 标准化实施记录

### 实施内容

对 7 个 skill 统一输出目录约定、result JSON 文件名模式与 envelope 字段，为后期跨 skill 汇总脚本建立数据基础。

1. **`skills/dnabert2/scripts/embed_interval_plot.py`**
   - `--output-dir` 默认值从 `.` 改为 `output/dnabert2`
   - 输出文件名从 `run_metadata.json` 改为 `dnabert2_embedding_{chrom}_{start}_{end}_result.json`
   - 新增 envelope 字段：`skill_id=dnabert2`、`task=embedding`、`outputs`

2. **`skills/nucleotide-transformer-v3/scripts/run_track_prediction.py`**
   - `--output-dir` 默认值从 `nucleotide-transformer-v3/outputs` 改为 `output/ntv3`
   - 输出文件名从 `{prefix}_meta.json` 改为 `{prefix}_result.json`
   - 新增 envelope 字段：`skill_id=nucleotide-transformer-v3`、`task=track-prediction`、`outputs`

3. **`skills/segment-nt/scripts/run_segment_nt_region.py`**
   - 输出文件名从 `{prefix}_meta.json` 改为 `{prefix}_result.json`
   - 新增 envelope 字段：`skill_id=segment-nt`、`task=track-prediction`、`outputs`

4. **`skills/alphagenome-api/scripts/run_alphagenome_predict_variant.py`**
   - 输出文件名从 `{chrom}_{pos}_{ref}_to_{alt}_summary.json` 改为 `alphagenome_variant-effect_{chrom}_{pos}_{ref}_to_{alt}_result.json`
   - 新增 envelope 字段：`skill_id=alphagenome-api`、`task=variant-effect`、`outputs`
   - `outputs` 字段在 `finally` 块中同步更新（确保路径最终态正确）

5. **`skills/evo2-inference/scripts/run_real_evo2_workflow.py`**
   - `--output-dir` 默认值从 `evo2-inference/results` 改为 `output/evo2`
   - 两个 workflow 结果 dict 分别新增 envelope 字段：
     - interval workflow：`skill_id=evo2-inference`、`task=embedding`
     - variant workflow：`skill_id=evo2-inference`、`task=variant-effect`
   - `result_json` 字段在 JSON 文件路径确定后回填

6. **`skills/gpn-models/references/predict_variant_single_site.py`**
   - 新增 `--output-dir` 参数，默认 `output/gpn-models`
   - 规范化输出路径：`gpn_variant-effect_{chrom}_{pos}_{ref}_to_{alt}_result.json`
   - `--output-json` 仍可显式覆盖路径（向后兼容）
   - 新增 envelope 字段：`skill_id=gpn-models`、`task=variant-effect`、`outputs`

7. **`skills/borzoi-workflows/scripts/run_borzoi_predict.py`** *(新建)*
   - borzoi-workflows 原无 Python 脚本，本次新建 fastpath 推理脚本
   - 依赖预下载的 mini-model 资产（`params.json` + `model0_best.h5` + `hg38/targets.txt`）
   - 输出产物：
     - `{prefix}_trackplot.png`：top-N 轨道 REF/ALT 对比图
     - `{prefix}_variant.tsv`：per-track SAD 表（`track_idx`, `identifier`, `description`, `SAD`）
     - `{prefix}_tracks.npz`：REF/ALT 原始预测数组
     - `{prefix}_result.json`：共享 envelope + 运行元数据
   - 默认输出目录：`output/borzoi`
   - envelope 字段：`skill_id=borzoi-workflows`、`task=variant-effect`

### 统一 envelope 字段格式

所有 skill 的 result JSON 顶层现包含：

```json
{
  "skill_id": "<skill-id>",
  "task": "<task-type>",
  "outputs": {
    "plot": "<path-or-null>",
    "npz": "<path-or-null>",
    "result_json": "<self-path>"
  }
}
```

### 验证结果

- `grep -n 'skill_id' skills/*/scripts/*.py skills/gpn-models/references/*.py` 全部命中，7 个 skill 均已添加
- `grep -n '_result.json' skills/*/scripts/*.py` 确认新文件名模式生效
- `output/dnabert2`、`output/ntv3`、`output/borzoi`、`output/gpn-models` 为新默认输出目录

最后更新：2026-03-29

> 说明：项目规划已统一迁移至 `DEVELOPMENT_PLAN.md`，本文件仅维护进度与验证记录。

## 2026-03-30：基因组数据输入优化实施记录

### 背景

`run_agent.sh` 的 `input_satisfied()` 因 `sequence-or-interval` 与 `coordinate-or-interval` 的 query_tokens 大量重叠（均含 `chr`/`start`/`end`/`interval`），导致区间查询同时命中两个 key，代理无法区分 track-prediction 与 variant-effect 任务，且 `coordinate-or-interval` 缺少单位点专有 token（`pos`/`site`/`locus`），坐标系语义完全缺失。

### 实施内容

**全部改动仅涉及 YAML/shell 层，未修改任何 Python argparse 逻辑。**

#### 1. `registry/input_schema.yaml`

- **`sequence-or-interval`**：顶层 query_tokens 去掉 `chr`；新增 `subtypes` 字段（`raw-sequence` / `genomic-interval`，语义注解，不影响 awk 解析）
- **`coordinate-or-interval`**：去掉 `interval`，新增 `pos`/`site`/`locus` 专有 token；新增 `subtypes`（`single-site` 含 `coordinate_system: 1-based` / `variant-interval` 含 `coordinate_system: 0-based [start, end)`）
- **`legacy_key_map`**：删除 `chrom: coordinate-or-interval`（单独 chrom token 不构成完整坐标，已由 query_tokens 中的 `chr` 覆盖）
- **`coordinate_conventions`**：新增 `assembly_aliases`（hg19→GRCh37, hg38→GRCh38, mm10→GRCm38, chm13→T2T-CHM13）
- **`assembly`**：examples 补充 `hg19`；query_tokens 补充 `grch38`/`grch37`
- **遗留 `sequence` key**：添加 `deprecated: true` + `replaced_by: sequence-or-interval`

#### 2. `skills/evo2-inference/skill.yaml`

- `sequence-or-interval` mapping：query_tokens 去掉 `chr`，加 `fasta`
- `coordinate-or-interval` mapping：query_tokens 去掉 `chr`/`interval`，加 `pos`/`site`/`locus`；`script_flags` 只保留 `--variant-coordinate`（原错误包含 `--interval`）
- 新增 constraint：`interval-flag-is-0based-half-open-variant-coordinate-flag-is-1based-single-site`

#### 3. 全部 8 个 stable skill.yaml

| Skill | 改动内容 |
|---|---|
| `alphagenome-api` | coordinate mapping 去掉 `interval`/`start`/`end`，加 `pos`/`site`/`locus`；新增 constraint `variant-coordinate-is-1based-single-site` |
| `nucleotide-transformer-v3` | sequence mapping 去掉 `chr` 加 `fasta`；新增 constraint `interval-is-0based-half-open-ucsc-fetched` |
| `dnabert2` | sequence mapping 去掉 `chr` 加 `fasta`；新增 constraint `interval-is-0based-half-open-ucsc-fetched` |
| `segment-nt` | sequence mapping 去掉 `chr` 加 `fasta`；coordinate mapping 加 `pos`/`site`/`locus`；新增 constraint `interval-is-0based-half-open-no-N-bases` |
| `gpn-models` | coordinate mapping 去掉 `interval`/`start`/`end`，加 `pos`/`site`/`locus`；新增 constraint `variant-pos-is-1based-chrom-pos-separate-flags` |
| `borzoi-workflows` | sequence mapping 去掉 `chr` 加 `fasta`；coordinate mapping 去掉 `interval`，加 `pos`/`site`/`locus`；新增 constraint `interval-is-0based-half-open-variant-coordinate-is-1based-vcf-style` |

#### 4. `scripts/validate_input_contracts.sh`

- 在 stable skill mapping 验证循环后插入坐标系 annotation 缺失检测：涉及 `coordinate-or-interval` 或 `sequence-or-interval` 的 mapping，若既无 `coord_system=` 字段，skill constraints 中也无 `based` 关键词，则输出 `warn`（不 exit 1，不破坏现有测试）

### 验证结果

- `bash scripts/validate_input_contracts.sh`：`passed for 7 stable skill(s) with 0 warning(s)`
- `bash scripts/smoke_test.sh`：`smoke test passed`（全部 28 项通过）

## 2026-03-30：skill-factory 晋升 stable 与 CI 修复记录

### 背景

前次提交（`b31e6c2`）将 `skill-factory` 从 `skills-dev/` 晋升至 `skills/`，并在路由注册表中启用。晋升触发了两类 CI 回归：

1. `validate_input_contracts.sh`：stable skill 必须声明 `input_mappings`，且所有输入 key 须在 `registry/input_schema.yaml` 的 22 个 canonical key 中可解析。
2. `evals/routing/cases.yaml` 中的 `route_015`：该用例在 skill-factory 未启用时被写为 `expected_decision: clarify`，晋升后 router 以 score 245（`$skill-factory` 显式提及）命中 skill-factory，导致预期不符。

### 实施内容

#### 1. `skills/skill-factory/skill.yaml`

- 原有 `required_inputs` / `optional_inputs` 使用了非 canonical key：`spec-json`、`output-root`、`overwrite`、`registry-update`、`include-references`、`include-real-run-script`，均不在 input schema 22 个 key 中。
- 全部替换为 canonical 等价 key：
  - `spec-json` → `task-objective`（描述 scaffold 意图的自由文本）
  - `output-root` → `output-dir`
  - `overwrite` / `registry-update` / `include-*` → `runtime-context`（通用运行时控制标志）
- 新增 `input_mappings` 块：

  ```yaml
  required_inputs:
    - task-objective
  optional_inputs:
    - output-dir
    - runtime-context
  input_mappings:
    - task-objective|query_tokens=scaffold,create,generate,build,skill,spec|script_flags=--spec
    - output-dir|query_tokens=output,output-root,skills-dev,dev,stable|script_flags=--output-root
    - runtime-context|query_tokens=overwrite,replace,regenerate,no-register,register|script_flags=--overwrite
  ```

#### 2. `evals/routing/cases.yaml`

- `route_015` 从 `expected_decision: clarify` 更新为直接路由预期：

  ```yaml
  - id: route_015
    query: "Use $skill-factory to scaffold a new skill from a JSON spec."
    expected_primary_skill: skill-factory
    expected_secondary_skills: []
    task: skill-scaffold
  ```

### 验证结果

- `bash scripts/validate_input_contracts.sh`：`passed for 8 stable skill(s) with 0 warning(s)`
- `bash scripts/validate_routing.sh`：routing eval 15/15 通过
- `make validate-agent`：全部 5 项检查通过

### 提交记录

- 提交 `7acceb4`（`fix(ci): fix skill-factory input_mappings and update route_015 eval case`）已推送至 `main`
- 改动文件：`skills/skill-factory/skill.yaml`（+8/-5）、`evals/routing/cases.yaml`（+3/-3）

## 2026-03-30：docs/ 参考文档体系构建

### 背景

`docs/` 目录仅有 `architecture.md` 一个文件，缺乏面向开发者/用户的统一参考页。路由逻辑、输入契约、skill 目录、脚本说明、安全策略、评测体系均散落在各子目录中，新用户无法快速定位。

### 实施内容

在 `docs/` 下新建 7 个参考文档，覆盖系统各层关键信息；更新 `docs/architecture.md` 增加 See Also 链接。

| 文件 | 内容摘要 |
|---|---|
| `docs/routing.md` | 路由评分权重表、置信度阈值、任务别名展开规则、task-to-skill 默认映射、调试方法 |
| `docs/input-schema.md` | 全 22 个规范输入 key 的类型/示例、坐标系约定、assembly 别名、遗留 key 映射 |
| `docs/contracts.md` | 8 个任务的输入契约、4 个任务的输出契约、恢复策略、run_agent.sh 契约使用方式 |
| `docs/skills-reference.md` | 11 个 skill（7 stable + 4 dev）的 family/tasks/triggers/状态一览表 |
| `docs/scripts-reference.md` | 19 个脚本按角色分组，含用途、关键 flag、依赖关系图、make 目标、环境变量 |
| `docs/safety.md` | 凭证保护、执行风险控制、科学护栏、groundedness 策略、fallback 行为、扩展指引 |
| `docs/evals.md` | 3 个 eval suite 说明、8 个验证脚本、如何运行/解读输出、如何新增测试用例 |

### 验证结果

- `git add docs/ && git commit`：提交 `1b65cac`，8 文件变更，+812 行。
- `git push origin main`：已推送至 `JiaqiLiZju/s2f-agent`。
- 所有交叉链接在 docs/ 内部可解析，无破坏性改动。

## 2026-03-30：公开发布准备（README 优化 + CHANGELOG + CONTRIBUTING）

### 背景

项目计划面向社区公开发布（`JiaqiLiZju/s2f-agent`），需建立规范的文档基础设施。

### 实施内容

#### 1. README.md 优化

- 精简一句话描述，突出 genomics workflow agent 定位。
- 修正 Star History 徽章仓库 slug：`s2fm_agent` → `s2f-agent`。
- 更新 Skill Factory 状态标注：Dev → Stable。
- Bootstrap 章节前置（用户第一关注点）。
- 移除 Maintainers 小节，替换为 CONTRIBUTING.md 跳转链接。

#### 2. CHANGELOG.md 新建

- 以 `v0.1.0` 为初始公开发布版本。
- 汇总所有主要里程碑：agent 骨架、routing、input schema、skill output 标准化、ENV 预检等。

#### 3. CONTRIBUTING.md 新建

- Skill 编写规范（`SKILL.md + skill.yaml + scripts/` 结构）。
- PR 提交流程与发布前验收 checklist（`validate-agent` / `eval-routing` / `smoke-lite`）。
- 维护者联系方式迁移自原 README。

### 验证结果

- `git push origin main` 成功，提交 `55d1534` 已推送至 `JiaqiLiZju/s2f-agent`。
- 3 文件变更：`README.md`（修改）、`CHANGELOG.md`（新建）、`CONTRIBUTING.md`（新建），共 +108 / -32 行。

## 2026-03-29：Execute Plan ENV 预检实施与优化记录

### 实施内容

1. 在 `scripts/execute_plan.sh` 实现 ENV 预检流程：
   - 解析 routed primary skill 的 `skill.yaml`（优先使用 `run_agent` 返回的 `skill_metadata` 路径，失败时回退到 registry 查找）。
   - 读取 `required_env`、`optional_env`、`required_env_any`。
   - 组合 process env + repo `.env` 的可见性视图（process env 优先）。
2. 执行策略落地：
   - `--run`：ENV 预检失败直接阻断（在首个 `run step` 之前）。
   - `--dry-run`：仅报告 `env_precheck` 状态，不阻断。
3. 输出结构增强：
   - text 输出新增 `env_precheck` 块（skill/status/missing_required/missing_any_groups/source_summary）。
   - json 输出新增 `env_precheck` 对象（增量字段，向后兼容）。
4. skill 合同字段首批落地：
   - `skills/alphagenome-api/skill.yaml`：
     - `required_env: [ALPHAGENOME_API_KEY]`
     - `optional_env: [http_proxy, https_proxy, grpc_proxy]`
   - `skills/nucleotide-transformer-v3/skill.yaml`：
     - `required_env: [HF_TOKEN]`
   - `skills/evo2-inference/skill.yaml`：
     - `required_env_any: [NVCF_RUN_KEY|EVO2_API_KEY]`
5. 教程优化（与预检行为一致）：
   - `tutorials/README.md` 补充 ENV 预检前置说明。
   - `tutorials/01-quickstart-agent.md` 补充 `env precheck failed` 排障提示。
   - `tutorials/06-troubleshooting-and-clarify.md` 补充 one-of key 说明与预检验证示例。

### 验证结果

1. 语法与基本行为：
   - `bash -n scripts/execute_plan.sh` 通过。
2. 预检行为验证（通过临时隔离 `.env` 做缺失场景）：
   - alphagenome `--run` 缺失 `ALPHAGENOME_API_KEY`：
     - 返回码 `1`，命中 `error: env precheck failed`，且未执行 `run step`。
   - alphagenome `--dry-run` 缺失 key：
     - 返回码 `0`，`env_precheck.status=fail`，仍输出 dry-run steps。
   - evo2 `--run` 缺失 `NVCF_RUN_KEY` + `EVO2_API_KEY`：
     - 返回码 `1`，命中 any-of 组缺失提示，且未执行 `run step`。
   - evo2 `--dry-run` 仅提供 `NVCF_RUN_KEY`：
     - 返回码 `0`，`env_precheck.status=pass`。
3. 回归验证：
   - `make validate-agent` 全通过（包含 routing eval 15/15）。

### 本次优化结论

1. 将“凭证缺失失败点”前移到 execute 入口，降低真实执行阶段失败成本。
2. `required_env_any` 解决了 Evo2 双 key 兼容需求（严格性与可用性兼顾）。
3. 预检信息可读性提升（text/json 同步输出），便于 agent 端和用户端快速定位配置问题。

### AlphaGenome 真实执行与 agent/skill 定向优化（2026-03-28）

已完成一次真实 `AlphaGenome` `predict_variant` 执行，并基于执行日志完成 `alphagenome-api` 相关 agent/skill 定向优化与回归验证。

#### 1. 真实执行记录

- 执行环境：
  - conda env：`/Users/jiaqili/miniconda3_arm/envs/alphagenome-py310`
  - Python `3.10.20`
  - `alphagenome 0.6.1`
- 真实推理配置：
  - assembly：`hg38`
  - 位点：`chr12:1,000,000`（1-based）
  - ALT：`G`
  - 脚本自动查询 REF（UCSC），实测 `REF=T`，实际突变为 `T>G`
  - `requested_outputs=[RNA_SEQ]`
  - `ontology_terms=["UBERON:0001157"]`
  - interval：`chr12:991808-1008192`（`16384 bp`）
- 连通性与回退：
  - 直连 `dna_client.create(...)` 首次触发 `grpc.FutureTimeoutError`
  - 使用代理变量 `grpc_proxy/http_proxy/https_proxy=http://127.0.0.1:7890` 后重试成功
- 真实产物：
  - `output/alphagenome/chr12_1000000_T_to_G_rnaseq_overlay.png`
  - `output/alphagenome/chr12_1000000_T_to_G_summary.json`
  - 摘要关键信息：`status=success`、`ref=T`、`alt=G`、`install_action=skip_import_ok`

#### 2. Agent 优化落地（`scripts/run_agent.sh`）

- 新增 AlphaGenome variant fastpath（仅在 `task=variant-effect` 且 `primary_skill=alphagenome-api` 时启用）。
- 新增参数抽取逻辑（中英文 query）：
  - `assembly`
  - `chrom`
  - `position`
  - `alt`
  - `output-dir`
  - `conda env`
- fastpath 生成单条主执行命令：
  - 调用 `skills/alphagenome-api/scripts/run_alphagenome_predict_variant.py`
- 自动注入一次代理回退命令到 `plan.fallbacks`：
  - `grpc_proxy/http_proxy/https_proxy=http://127.0.0.1:7890`
- `plan.expected_outputs` 动态包含：
  - `summary.json`
  - `rnaseq_overlay.png`
  - `alphagenome_predict_variant.log`

#### 3. Skill 与文档优化（`skills/alphagenome-api`）

- 脚本归档迁移：
  - `skills/alphagenome-api/scripts/run_alphagenome_predict_variant.py`
  - `.env` 发现机制升级为“从当前目录与脚本目录向上递归搜索”
- `skill.yaml` 增强：
  - `optional_inputs` 增加 `output-dir`、`runtime-context`、`network-proxy-endpoint`
  - `constraints` 增加 `set-timeout-and-proxy-fallback-for-real-runs`
- `SKILL.md` 增强：
  - `dna_client.create(API_KEY, timeout=...)`
  - `grpc.FutureTimeoutError` 的代理重试规范
  - 真实运行必须保留机器可读 summary
- `references/caveats.md` 增强：
  - gRPC 连通性预检（`gdmscience.googleapis.com:443`）
  - timeout 失败签名识别与代理切换指引
- `references/workflows.md` 增强：
  - 真实执行产物契约（plot + summary JSON 字段清单）
- `playbooks/variant-effect/README.md` 增强：
  - 新增 AlphaGenome 实跑命令与代理重试命令模板
- `registry/recovery_policies.yaml` 对齐：
  - `variant-effect` 策略更新为 `clarify-missing-inputs-then-connectivity-proxy-retry-once`

#### 4. 评测与回归扩展

- `evals/task_success/cases.yaml` 新增 `task_success_006`：
  - 使用中文 AlphaGenome 真实执行请求
  - 断言 `runnable_steps` 包含新脚本路径
  - 断言 `expected_outputs` 落在 `output/alphagenome`
- `scripts/validate_task_success.sh` 支持强化断言字段：
  - `required_step_contains`
  - `required_expected_output_contains`

#### 5. 本次验证结果

- `bash scripts/validate_task_success.sh`
  - 结果：`6/6 passed`
- `bash scripts/validate_routing.sh`
  - 结果：`15/15 passed`
- `bash scripts/validate_groundedness.sh`
  - 结果：`4/4 passed`
- `bash scripts/validate_skill_metadata.sh`
  - 结果：通过
- 手工抽检（中文完整 AlphaGenome 请求）：
  - `run_agent --format text/json` 均包含：
    - 主执行命令（非代理）
    - 代理 fallback 命令
    - `summary/plot/log` 三类 expected outputs
- 脚本可执行性：
  - `conda run -p /Users/jiaqili/miniconda3_arm/envs/alphagenome-py310 python skills/alphagenome-api/scripts/run_alphagenome_predict_variant.py --help` 返回正常

### NTv3 真实执行与 agent/skill 定向优化（2026-03-28）

已完成一次真实 `NTv3` track 预测执行，并基于执行结果完成 `nucleotide-transformer-v3` 相关 agent/skill 定向优化与回归验证。

#### 1. 真实执行记录

- 执行环境：
  - `conda run -n ntv3`
  - Python `3.10.18`
  - `transformers 4.57.6`
  - `torch 2.2.2`
  - `cuda_available=False`（CPU 路径）
- 真实推理配置：
  - model：`InstaDeepAI/NTv3_100M_post`
  - species：`human`
  - assembly：`hg38`
  - interval：`chr19:6700000-6732768`（长度 `32768`）
  - output-dir：`output/ntv3_results`
- 真实产物：
  - `output/ntv3_results/ntv3_human_hg38_chr19_6700000_6732768_trackplot.png`
  - `output/ntv3_results/ntv3_human_hg38_chr19_6700000_6732768_meta.json`
  - `output/ntv3_results/ntv3_run.log`
- 关键日志与元数据校验：
  - 日志包含 `loading config/tokenizer/model from HF` / `saved plot` / `saved meta`
  - `meta.json` 核心字段与请求一致（`species/assembly/chrom/start/end`）
  - `tracks_plotted` 非空

#### 2. Agent 优化落地（`scripts/run_agent.sh`）

- 新增 NTv3 track fastpath（仅在 `task=track-prediction` 且 `primary_skill=nucleotide-transformer-v3` 时启用）。
- 新增轻量参数抽取逻辑（从 query 解析）：
  - `species`（`human`/`mouse`）
  - `assembly`（`hg38`/`hg19`/`mm10`/`chm13`）
  - interval（支持 `chr:start-end` 与 `chrom/start/end`，并清洗 `_`/`,`）
  - output-dir（优先匹配 `output/...`，默认 `output/ntv3_results`）
- `output-head` 免澄清策略：
  - 当 query 已表达 track 输出意图（含 `track/trackplot/output` 与中文 `轨道/绘图/绘制/画图`）时，`output-head` 视为已提供。
- 生成真实可执行 plan：
  - `plan.runnable_steps` 直接输出单条可运行命令链（含 `.env` 注入、`conda run -n ntv3`、`tee` 记录日志）。
  - `plan.expected_outputs` 动态生成为精确 `trackplot/meta/log` 路径。
  - `plan.fallbacks` 增加同命令 `--disable-xet` 回退版本（不进入主 `runnable_steps`）。

#### 3. Skill 规范强化（`skills/nucleotide-transformer-v3/SKILL.md`）

- 新增 `Real Track Prediction Fastpath` 章节，明确：
  - 默认模型：`InstaDeepAI/NTv3_100M_post`
  - 默认输出目录：`output/ntv3_results`
  - CPU 可接受
  - 前置检查顺序：`HF_TOKEN -> gated 权限 -> conda 环境 -> UCSC/HF 网络`
  - 标准命令模板与 `--disable-xet` 回退模板
  - 验收清单（日志关键行 + plot/meta 文件 + 元字段）

#### 4. 评测与回归扩展

- 扩展 `scripts/validate_task_success.sh`：
  - 新增可选用例断言字段：
    - `required_step_contains`
    - `required_expected_output_contains`
- 更新 `evals/task_success/cases.yaml`：
  - 新增 `task_success_005`（中文 NTv3 实战 query）
  - 断言 `runnable_steps` 包含 `conda run -n ntv3 ... run_track_prediction.py`
  - 断言 `expected_outputs` 包含 `output/ntv3_results`

#### 5. 本次验证结果

- `bash scripts/run_agent.sh --task track-prediction --query "<中文完整请求>" --format json`
  - 命中 NTv3 fastpath，`missing_inputs=[]`
- `bash scripts/run_agent.sh --task track-prediction --query "<英文 chr19:6700000-6732768 请求>" --format json`
  - 命中 NTv3 fastpath，生成可执行命令与精确输出路径
- `bash scripts/run_agent.sh --task track-prediction --query "<缺失 interval 请求>" --format json`
  - 不触发 fastpath，保留 `missing_inputs=sequence-or-interval` 行为
- `bash scripts/execute_plan.sh --task track-prediction --query "<中文完整请求>" --dry-run --format text`
  - dry-run 展示真实执行命令与 verify 目标
- `bash scripts/validate_task_success.sh`
  - 结果：`5/5 passed`
- `bash scripts/validate_groundedness.sh`
  - 结果：`4/4 passed`

### s2f agent P0/P1 收口实施（2026-03-27）

按本轮“P0 收口 + P1 扩展”要求，已完成 `enabled` 运行时语义、输出标准化、计划执行最小闭环、评测与 CI 接入，并完成全链路回归。

#### 1. [x] 发布隔离与 `enabled` 生效（M1）

已落地：

- `registry/skills.yaml`
  - 将 `basset-workflows`、`bpnet`、`nucleotide-transformer`、`skill-factory` 标记为 `enabled: false`
- `scripts/lib_registry.sh`
  - 新增 `registry_get_scalar_field`
  - 新增 `registry_skill_enabled`
  - 新增 `registry_list_ids_filtered`
- 以下脚本默认仅处理 `enabled=true`，并支持 `--include-disabled` 显式包含禁用技能：
  - `scripts/link_skills.sh`
  - `scripts/route_query.sh`
  - `scripts/run_agent.sh`
  - `scripts/validate_registry.sh`
  - `scripts/validate_skill_metadata.sh`
  - `scripts/validate_routing.sh`
  - `scripts/smoke_test.sh`

新增：

- `scripts/validate_registry_tracking.sh`
  - 对 `enabled=true` 技能强制校验：
    - 目录存在
    - 路径未被 git ignore
    - 路径内存在 git 已跟踪文件
  - `enabled=false` 默认信息提示（可用 `--include-disabled` 开启严格检查）

接入：

- `Makefile`
  - 新增 `make validate-registry-tracking`
  - `make validate-agent` 已接入 tracking 校验

#### 2. [x] 任务术语统一与契约同步（M1 补齐）

已落地：

- 统一故障任务名：`troubleshooting`
- `setup` 统一降级为 alias 到 `environment-setup`

更新文件：

- `registry/task_contracts.yaml`
  - 新增 `task_aliases`：
    - `setup -> environment-setup`
    - `general-troubleshooting -> troubleshooting`
  - 移除 `contracts.setup`
- `registry/routing.yaml`
  - 新增 troubleshooting 相关 alias 归一
- `registry/tags.yaml`
  - 移除 `setup` tag 映射
- `registry/skills.yaml` 及对应 skill metadata
  - 相关 skill 的 task 从 `setup` 改为 `environment-setup`

文档同步：

- `agent/ROUTING.md`
- `agent/README.md`
- `docs/architecture.md`
- `README.md`

#### 3. [x] 四类核心任务输出标准化（M2）

新增：

- `registry/output_contracts.yaml`
  - 覆盖 `variant-effect` / `embedding` / `fine-tuning` / `track-prediction`
  - 统一字段：
    - `assumptions`
    - `runnable_steps`
    - `expected_outputs`
    - `fallbacks`
    - `retry_policy`

扩展：

- `scripts/run_agent.sh`
  - 新增参数：
    - `--output-contracts`
    - `--recovery`
    - `--include-disabled`
  - `decision=clarify` 时：输出 `plan: null`（json）/ `plan: none`（text）
  - `decision=route` 时：输出标准化 `plan` 对象（保留旧字段兼容）
    - `task`
    - `selected_skill`
    - `assumptions`
    - `required_inputs`
    - `missing_inputs`
    - `constraints`
    - `runnable_steps`
    - `expected_outputs`
    - `fallbacks`
    - `retry_policy`

#### 4. [x] plan -> execute -> verify 最小闭环（M3）

新增：

- `registry/recovery_policies.yaml`
  - 按任务定义 `retry_policy` 与 `fallback_skills`
- `scripts/execute_plan.sh`
  - 默认 `--dry-run`
  - 可选 `--run` 执行 `plan.runnable_steps`
  - 按 `expected_outputs` 执行基础验证（file/plot 检查）

#### 5. [x] `tool_contracts` 元数据扩展（M3）

已为现有 `skill.yaml` 增加 `tool_contracts` 字段（兼容保留 `tools`）：

- 所有稳定技能与开发技能均已具备 `tool_contracts`
- `scripts/validate_skill_metadata.sh` 增加校验：
  - `tool_contracts` 字段必须存在
  - 若 `tools` 非空，则 `tool_contracts` 必须非空

#### 6. [x] 评测扩展与治理（M4）

新增评测集：

- `evals/groundedness/cases.yaml`
- `evals/task_success/cases.yaml`

新增评测脚本：

- `scripts/validate_groundedness.sh`
- `scripts/validate_task_success.sh`

扩展：

- `evals/routing/cases.yaml`
  - 新增 disabled skill 边界 case
  - 更新相关 case 以适配发布隔离策略
- `scripts/smoke_test.sh`
  - 接入 groundedness/task-success/tracking 校验
  - 增加“disabled skill 默认不可路由”断言

#### 7. [x] CI 接入（M4）

新增：

- `.github/workflows/agent-ci.yml`

CI 任务包含：

1. `make validate-agent`
2. `make eval-routing`
3. `make eval-groundedness`
4. `make eval-task-success`
5. `make smoke-lite`

#### 8. [x] README 与入口更新

已更新 `README.md`：

- 新增 `plan standardization` 与 `plan execution` 能力说明
- 增加 `--include-disabled` 使用说明（route/run/link）
- 增加 `execute_plan.sh` 用法
- 增加 `validate_registry_tracking` / `eval-groundedness` / `eval-task-success` / `smoke-lite` 文档入口
- 更新仓库结构中 `registry/evals` 说明
- 增加 CI workflow 入口说明

#### 9. [x] 本轮验证记录

已执行并通过：

- `bash -n scripts/lib_registry.sh scripts/link_skills.sh scripts/route_query.sh scripts/run_agent.sh scripts/execute_plan.sh scripts/validate_registry.sh scripts/validate_registry_tracking.sh scripts/validate_skill_metadata.sh scripts/validate_routing.sh scripts/validate_groundedness.sh scripts/validate_task_success.sh scripts/validate_migration_paths.sh scripts/smoke_test.sh scripts/bootstrap.sh scripts/agent_console.sh`
- `make validate-agent`
- `make eval-routing`
- `make eval-groundedness`
- `make eval-task-success`
- `make smoke-lite`
- `bash scripts/smoke_test.sh`
- `bash scripts/execute_plan.sh --task track-prediction --query 'Need track-prediction plan for human hg38 interval and head output.'`

关键结果：

- `validate-agent`：通过（已包含 registry tracking）
- `validate-routing`：`15/15 passed`
- `validate-groundedness`：`4/4 passed`
- `validate-task-success`：`4/4 passed`
- `smoke_test`：通过（新增评测与 disabled 路由断言）
- `run_agent --format json`：已输出标准化 `plan` 对象
- `execute_plan`：dry-run 闭环可用

当前结论：

- 已完成本轮 P0/P1 计划内核心工程项落地。
- 仓库已具备“发布隔离 + 标准化计划输出 + 最小执行闭环 + 多维评测 + CI”能力。

### 本次执行确认（2026-03-27）

按用户本轮指令已完成并记录：

1. 将 `borzoi-workflows` 迁移到 `skills/borzoi-workflows`。
2. 与已迁移 wave 技能策略保持一致：不保留根目录兼容目录/软链接。
3. 迁移后全链路验证通过：
   - `validate_registry`
   - `validate_skill_metadata`
   - `validate_migration_paths`
   - `validate_routing`（`14/14 passed`）
   - `smoke_test`
   - `validate-agent`

当前结论：

- `borzoi-workflows` 已纳入命名空间迁移集合。
- 主运行链路已可在无根目录兼容层条件下稳定工作。

### Borzoi 迁移补充（2026-03-27）

按用户要求，已将 `borzoi-workflows` 迁移到 `skills/` 命名空间并完成一致性校验。

- `registry/skills.yaml`
  - `borzoi-workflows.path` 更新为 `skills/borzoi-workflows`
- `skills/borzoi-workflows/skill.yaml`
  - `path` 更新为 `skills/borzoi-workflows`
- 目录动作：
  - `borzoi-workflows/` 已迁移到 `skills/borzoi-workflows/`
  - 根目录 `borzoi-workflows` 兼容路径已移除（与已迁移 wave-1 技能策略一致）
- `registry/migration_wave1.yaml`
  - 已纳入 `borzoi-workflows`
  - 迁移描述更新为“迁移后移除根目录 legacy path”

验证结果：

- `bash scripts/validate_registry.sh` 通过
- `bash scripts/validate_skill_metadata.sh` 通过
- `bash scripts/validate_migration_paths.sh` 通过（`7/7`）
- `bash scripts/validate_routing.sh` 通过（`14/14 passed`）
- `bash scripts/smoke_test.sh` 通过
- `make validate-agent` 通过

### Borzoi 真实执行、结果归档与 skill/routing 回灌（2026-03-27）

本轮按用户真实需求，完成了一次 Borzoi 端到端执行（track prediction + single-site variant effect），并将执行经验同步回 `borzoi-workflows` 文档与路由层。

#### 1. 真实执行目标

- 使用 Borzoi 执行真实 track prediction：
  - `species = "human"`
  - `assembly = "hg38"`
  - 区间：`chr19:6,700,000-6,732,768`
  - 产出 trackplot
- 使用 Borzoi 执行真实 variant effect：
  - 位点：`hg38 chr12:1,000,000`（1-based）
  - 规则：若 REF 不是 `G` 则 ALT=`G`；若 REF 是 `G` 则 ALT=`T`
  - 保存突变效应结果到 `output`

#### 2. 本次真实执行结果

执行环境与模型路径：

- Python：`/Users/jiaqili/miniconda3_arm/envs/borzoi_py310/bin/python`
- 运行模型：`borzoi_mini_k562_rna_f0`（真实权重推理）
- 运行脚本：`output/run_borzoi_real_predictions.py`

核心结果文件（执行后）：

- `output/borzoi_trackplot_chr19_6700000_6732768.png`
- `output/borzoi_track_prediction_chr19_6700000_6732768.npz`
- `output/borzoi_track_top_tracks_chr19_6700000_6732768.tsv`
- `output/borzoi_predict_variant_chr12_1000000.tsv`
- `output/borzoi_predict_variant_chr12_1000000_tracks.npz`
- `output/borzoi_variant_trackplot_chr12_1000000.png`
- `output/borzoi_run_metadata.json`

本次位点实际解析结果：

- `chr12:1,000,000` 参考碱基 `REF = T`
- 按规则得到 `ALT = G`

#### 3. 输出整理动作

按用户要求，已将本次 Borzoi 相关输出统一整理到：

- `/Users/jiaqili/Desktop/s2f-skills/output/borzoi`

包括模型与配置缓存目录：

- `/Users/jiaqili/Desktop/s2f-skills/output/borzoi/borzoi_mini_k562`

#### 4. 基于真实执行的 borzoi-workflows skill 更新

更新文件：

- `borzoi-workflows/SKILL.md`
- `borzoi-workflows/references/setup-and-env.md`
- `borzoi-workflows/references/tutorial-playbooks.md`
- `borzoi-workflows/references/variant-and-interpretation.md`
- `borzoi-workflows/references/real-inference-fastpath.md`（新增）

关键改动：

1. 新增推理分层决策：
   - `full` / `fast` / `offline`
2. `fast` 人类默认模型建议：
   - 默认优先 `mini/human_gtex`（或 `human_all`）
   - `k562_*` 仅在用户显式指定 K562 时使用
3. 增加环境 preflight 与多 conda 安全建议
4. 修正文档命令错误：
   - `python analyze_indel.sh` -> `bash analyze_indel.sh`
5. 新增真实推理 fastpath 参考：
   - 轻量资产下载
   - 局部序列获取策略
   - 1-based/0-based 坐标规范
   - 单点突变输出契约（png/tsv/npz/json）

#### 5. agents 与 routing 同步

更新文件：

- `borzoi-workflows/agents/openai.yaml`
- `evals/routing/cases.yaml`
- `registry/skills.yaml`

同步内容：

1. `openai.yaml` 文案升级为“full/fast inference + variant + interpretation”
2. 新增 Borzoi fast-tier 路由用例：
   - `route_013`（track prediction）
   - `route_014`（predict_variant 规则化突变）
3. `registry/skills.yaml` 中 `borzoi-workflows` 补充：
   - task：`track-prediction`
   - trigger：`human_gtex`

#### 6. 本轮验证记录

已执行：

- `bash scripts/validate_routing.sh`

结果：

- `routing eval summary: 14/14 passed`

### 测试技能命名空间迁移（2026-03-27）

已按 agent 迁移设计，完成指定测试 skills 的 `skills/` 命名空间迁移，并保留根目录兼容软链接。

#### 1. 本轮迁移范围（用户确认）

- `alphagenome-api`
- `nucleotide-transformer-v3`
- `gpn-models`
- `evo2-inference`
- `dnabert2`
- `segment-nt`

#### 2. 迁移实施内容

新增：

- `registry/migration_wave1.yaml`（迁移清单）
- `scripts/validate_migration_paths.sh`（迁移路径与兼容层校验）

更新：

- `registry/skills.yaml`
  - 上述 6 个 skill 的 `path` 已更新为 `skills/<skill-id>`
- 对应 skill metadata：
  - `skills/alphagenome-api/skill.yaml`
  - `skills/nucleotide-transformer-v3/skill.yaml`
  - `skills/gpn-models/skill.yaml`
  - `skills/evo2-inference/skill.yaml`
  - `skills/dnabert2/skill.yaml`
  - `skills/segment-nt/skill.yaml`
  - `path` 字段同步更新为 `skills/<skill-id>`
- `Makefile`
  - 新增 `make validate-migration-paths`
  - `make validate-agent` 已接入迁移路径校验
- `scripts/smoke_test.sh`
  - 新增 `validate_migration_paths.sh` 存在性与执行检查

目录动作：

- 已将 6 个目标目录迁移至 `skills/` 下
- 已在仓库根保留同名软链接作为兼容层（`<skill-id> -> skills/<skill-id>`）

#### 3. 本轮验证记录

已执行并通过：

- `bash -n scripts/validate_migration_paths.sh scripts/smoke_test.sh scripts/route_query.sh scripts/run_agent.sh scripts/validate_routing.sh scripts/validate_registry.sh scripts/validate_skill_metadata.sh scripts/link_skills.sh scripts/bootstrap.sh scripts/provision_stack.sh scripts/agent_console.sh`
- `bash scripts/validate_registry.sh`
- `bash scripts/validate_skill_metadata.sh`
- `bash scripts/validate_routing.sh`
- `bash scripts/validate_migration_paths.sh`
- `bash scripts/smoke_test.sh`
- `make validate-agent`

关键结果：

- `validate_registry`: 10/10 skills 路径解析通过（迁移 skill 已指向 `skills/`）
- `validate_skill_metadata`: 10/10 skills，0 warning
- `validate_routing`: `12/12 passed`
- `validate_migration_paths`: `6/6` 指定迁移 skill 校验通过
- `smoke_test` 与 `validate-agent` 全链路通过

### 临时开发技能区直迁落地（2026-03-27）

根据本轮最新要求，已执行“直接迁移 + 修改入口”，不保留软链接兼容层，用于下一轮临时开发测试。

#### 1. 目录调整结果

已创建临时开发目录：

- `skills-dev/`

已直接迁移以下 4 个 skills 到 `skills-dev/`：

- `skills-dev/basset-workflows`
- `skills-dev/bpnet`
- `skills-dev/nucleotide-transformer`
- `skills-dev/skill-factory`

已移除所有此前用于过渡的软链接（根目录与 `skills/` 下均无对应 symlink）。

#### 2. 入口关系与 metadata 同步

已更新：

- `registry/skills.yaml`
  - `basset-workflows` 路径改为 `skills-dev/basset-workflows`
  - `bpnet` 路径改为 `skills-dev/bpnet`
  - `nucleotide-transformer` 路径改为 `skills-dev/nucleotide-transformer`
  - 新增 `skill-factory` 条目，路径 `skills-dev/skill-factory`

- `registry/tags.yaml`
  - 补充 `skill-factory` 对应 tasks：
    - `skill-scaffold`
    - `skill-registry-update`
    - `skill-template-generation`
    - `skill-validation`

- 以下 skill metadata 路径字段已同步到 `skills-dev/...`：
  - `skills-dev/basset-workflows/skill.yaml`
  - `skills-dev/bpnet/skill.yaml`
  - `skills-dev/nucleotide-transformer/skill.yaml`
  - `skills-dev/skill-factory/skill.yaml`

- `skills-dev/skill-factory/SKILL.md`
  - 工厂命令示例入口已改为 `skills-dev/skill-factory/scripts/...`

- `README.md`
  - 已将上述 4 个技能的文档链接更新到 `skills-dev/` 路径
  - 当前技能总数同步为 11（含 `skill-factory`）
  - 增加 `skills-dev/` 临时开发区说明

#### 3. 验证记录

已执行并通过：

- `bash scripts/validate_registry.sh`
- `bash scripts/validate_skill_metadata.sh`
- `bash scripts/link_skills.sh --list`
- `bash scripts/route_query.sh --query 'Use $skill-factory to scaffold a new skill from a JSON spec.'`
- `bash scripts/smoke_test.sh`

关键结果：

- registry 与 metadata 均通过，当前识别 `11` 个 skills
- `skill-factory` 可被路由器正确命中
- 仓库级 `smoke_test` 通过

#### 4. 当前注意事项

- `.gitignore` 当前包含 `skills-dev/`
- 这意味着 `skills-dev/` 下内容默认不会被纳入 Git 跟踪，符合“临时测试区”定位
- 测试完成后若要并入正式 agent skills，需要单独执行正式迁移与跟踪策略调整

### s2f agent v2（推荐路线）已落地（2026-03-26）

按“路由质量优先 + deterministic + 低置信先澄清”的推荐路线，已完成以下增强：

#### 1. 路由配置化与任务同义词归一

新增：

- `registry/routing.yaml`

落地内容：

- 将路由权重从脚本硬编码迁移到机器可读配置（显式 skill / trigger / task alignment 等）
- 新增 task alias 规则（如 `set up` -> `environment-setup`、`fine tune` -> `fine-tuning`）
- 新增 confidence 阈值配置与 clarify 行为配置

#### 2. runtime router 增强（confidence + clarify）

更新：

- `scripts/route_query.sh`

新增能力：

- 输出 `decision`（`route` / `clarify`）
- 输出 `confidence`（level + score）
- 低置信场景返回单一聚焦澄清问题（而非静默硬路由）
- task 对齐从“仅 skill.tasks”增强为“skill.tasks + tags 映射”

#### 3. task-level 输入契约落地

新增：

- `registry/task_contracts.yaml`

更新：

- `scripts/lib_registry.sh`（新增 task contract 读取函数）
- `scripts/run_agent.sh`

行为变更：

- `run_agent.sh` 优先使用 task-level required inputs
- 若 task contract 缺失，再回退到 skill-level required inputs
- 明确输出 `required_inputs_source`
- 支持 router 的 `clarify` 决策直通输出

#### 4. 路由评测扩展（覆盖 clarify）

更新：

- `evals/routing/cases.yaml`
- `scripts/validate_routing.sh`

新增覆盖：

- 多 skill 歧义 query
- 无 task + 低置信 query 的 clarify 路径
- clarify 问题内容匹配校验

#### 5. smoke test 去耦合与扩展

更新：

- `scripts/smoke_test.sh`

落地内容：

- 新增 `registry/routing.yaml`、`registry/task_contracts.yaml` 存在性检查
- helper 脚本路径改为 registry 派生（降低目录迁移耦合）
- 新增 clarify 行为冒烟校验

#### 6. 文档同步

更新：

- `README.md`
- `docs/architecture.md`
- `agent/README.md`
- `agent/ROUTING.md`

重点同步：

- route/clarify 双决策模型
- confidence 输出
- task contract 输入契约策略

#### 7. 本轮验证记录

已执行并通过：

- `bash -n scripts/lib_registry.sh scripts/route_query.sh scripts/run_agent.sh scripts/validate_routing.sh scripts/smoke_test.sh`
- `bash scripts/validate_skill_metadata.sh`
- `bash scripts/validate_routing.sh`
- `bash scripts/smoke_test.sh`
- `make validate-agent`

关键结果：

- `validate_routing.sh`：`routing eval summary: 12/12 passed`
- `validate_skill_metadata.sh`：`10/10` skills，`0 warning(s)`
- `smoke_test.sh`：通过（新增 clarify 行为与新 registry 文件检查）
- `validate-agent`：全链路通过

### Segment-NT 真实执行与 skill 回灌（2026-03-26）

本轮按用户真实需求完成了 SegmentNT 端到端执行，并将执行经验回灌到 skill 文档与 helper 脚本。

#### 1. 真实执行目标

- 在 conda 环境安装 `segment-nt` 依赖并完成可运行验证
- 运行真实区间预测：
  - `species = "human"`
  - `assembly = "hg38"`
  - `chrom = "chr19"`, `start = 6_700_000`, `end = 6_732_768`
- 输出并保存 trackplot

#### 2. 执行过程关键点

1. 发现并规避架构问题：
   - 旧 `/usr/local/anaconda3` 环境为 x86 栈，JAX 在 Apple Silicon 上触发 AVX/jaxlib 问题
   - 新装 arm64 Miniconda：`/Users/jiaqili/miniconda3_arm`
   - 新建环境：`segmentnt`（Python 3.10）

2. 安装与推理：
   - 安装 JAX/Haiku/绘图与请求依赖
   - 安装 `nucleotide_transformer`（使用本地源码包路径安装）
   - 新增并执行区间推理脚本：`segment-nt/scripts/run_segment_nt_region.py`

3. 真实结果产物：
   - `/Users/jiaqili/Desktop/s2f-skills/output/segment-nt/segmentnt_human_hg38_chr19_6700000_6732768_trackplot.png`
   - `/Users/jiaqili/Desktop/s2f-skills/output/segment-nt/segmentnt_human_hg38_chr19_6700000_6732768_probs.npz`
   - `/Users/jiaqili/Desktop/s2f-skills/output/segment-nt/segmentnt_human_hg38_chr19_6700000_6732768_meta.json`

#### 3. 基于真实执行的 skill 改进

更新了以下内容：

- `segment-nt/scripts/compute_rescaling_factor.py`
  - 将 bp->token 计算从近似改为与 SegmentNT tokenizer 一致的 no-`N` 精确公式
  - 增加 `num_full_6mer_tokens`、`num_single_nt_tokens` 等可解释输出
- `segment-nt/SKILL.md`
  - 补充精确 token 规则、`bp % 24 == 0` 实用约束
  - 明确 `segment_nt_multi_species` 为 checkpoint family 语义而非 runtime species token
  - 增加真实区间脚本优先路径
- `segment-nt/references/constraints.md`
  - 补充输出长度与坐标映射注意事项
- `segment-nt/references/inference-patterns.md`
  - 将 SegmentNT 示例改为精确 token 计算版
- `segment-nt/references/setup-and-troubleshooting.md`
  - 新增 Apple Silicon x86/AVX 故障条目
  - 新增真实区间 smoke 命令
  - 增加大模型下载 `.incomplete` cache 说明
- `segment-nt/references/family-selection.md`
  - 补充 multi-species checkpoint 语义说明
- `segment-nt/skill.yaml`
  - tools 新增 `scripts/run_segment_nt_region.py`
  - optional_inputs 新增 `species`/`assembly`/`genomic-interval`
- `README.md`
  - scripts 示例列表新增 `segment-nt/scripts/run_segment_nt_region.py`

#### 4. 提交与远程同步

- 提交信息：`refine segment-nt skill based on real inference run`
- commit：`c0cb896`
- push：`origin/main`（成功）

## s2f agent 化规划（2026-03-26，已迁移）

该章节规划内容已迁移到 `DEVELOPMENT_PLAN.md`：

- 迁移位置：`从 DEVELOPMENT_PROGRESS.md 迁移的规划内容 / A. s2f agent 化规划`
- 维护约定：后续规划只在 `DEVELOPMENT_PLAN.md` 更新

### s2f agent 化第一阶段已落地（2026-03-26）

已按“主 agent + registry + playbook + eval”方向完成第一阶段重构，且保持现有 skill 根目录兼容。

#### 1. 新增主 agent 层

新增目录与文件：

- `agent/SYSTEM.md`
- `agent/ROUTING.md`
- `agent/SAFETY.md`
- `agent/agent.yaml`

主要内容：

- 明确主 agent 的职责是“路由 + 约束 + 输出一致性”，不替代各 skill 细节
- 固化任务分类、候选 skill 选择、缺失输入处理、约束过滤流程
- 补充凭证处理、风险操作、科学约束、groundedness guardrails

#### 2. 新增 registry 层

新增目录与文件：

- `registry/skills.yaml`
- `registry/tags.yaml`

主要内容：

- 建立全量 10 个 skill 的机器可读索引（`id`、`path`、`tasks`、`triggers` 等）
- 建立任务标签到 skill 的映射，供路由与评测复用

#### 3. 试点 skill 机器可读 metadata

新增以下试点 `skill.yaml`：

- `alphagenome-api/skill.yaml`
- `dnabert2/skill.yaml`
- `nucleotide-transformer-v3/skill.yaml`

主要字段：

- `id`、`family`、`tasks`、`triggers`
- `required_inputs` / `optional_inputs`
- `constraints`
- `tools`
- `priority_rules`

#### 4. 新增 playbook 层

新增：

- `playbooks/variant-effect/README.md`
- `playbooks/embedding/README.md`

主要内容：

- 各任务的最小输入契约
- 候选 skill 集合与路由启发式
- 回答输出契约（选择理由、假设、可执行示例、caveat）

#### 5. 新增 evals 路由样例

新增：

- `evals/routing/cases.yaml`

包含首批路由 case，用于验证：

- 显式 skill 调用
- 模型名触发
- 硬件限制下的 fallback 候选

#### 6. 脚本层重构（去硬编码）

新增脚本：

- `scripts/lib_registry.sh`
- `scripts/validate_registry.sh`

更新脚本：

- `scripts/link_skills.sh`
  - skill 列表改为读取 `registry/skills.yaml`
  - 新增参数：`--registry FILE`
- `scripts/smoke_test.sh`
  - skill 校验改为读取 `registry/skills.yaml`
  - 新增参数：`--registry FILE`
  - 新增对 `agent/`、`registry/`、`playbooks/`、`evals/`、试点 `skill.yaml` 的检查
- `Makefile`
  - 新增 `make validate-registry`

#### 7. 文档更新

更新：

- `README.md`
  - 新增 orchestration layer 说明
  - 新增 registry 校验命令
  - 更新仓库结构展示
- 新增 `docs/architecture.md`
  - 总结分层设计与迁移兼容策略

#### 8. 本轮验证记录

已执行并通过：

- `bash -n scripts/lib_registry.sh scripts/validate_registry.sh scripts/link_skills.sh scripts/smoke_test.sh scripts/bootstrap.sh scripts/provision_stack.sh`
- `bash scripts/validate_registry.sh`
- `bash scripts/link_skills.sh --list`
- `bash scripts/smoke_test.sh`

结果：

- registry 可正确枚举 10 个 skill
- `link_skills.sh --list` 输出与 registry 一致
- 仓库级 smoke test 通过，且覆盖新增 orchestration 层文件

### s2f agent 化第二阶段已落地（2026-03-26）

在第一阶段基础上，已继续完成“metadata 全量化 + 路由评测脚本化”。

#### 1. 全量补齐 `skill.yaml`

已为剩余 7 个 skill 新增机器可读 metadata：

- `basset-workflows/skill.yaml`
- `bpnet/skill.yaml`
- `borzoi-workflows/skill.yaml`
- `evo2-inference/skill.yaml`
- `gpn-models/skill.yaml`
- `nucleotide-transformer/skill.yaml`
- `segment-nt/skill.yaml`

结合第一阶段已有的 3 个试点（`alphagenome-api`、`dnabert2`、`nucleotide-transformer-v3`），当前 10 个已打包 skill 均已具备 `skill.yaml`。

#### 2. 路由评测能力落地

新增脚本：

- `scripts/validate_routing.sh`

功能：

- 读取 `evals/routing/cases.yaml`
- 结合 `registry/skills.yaml` 的 `tasks/triggers` 进行打分路由
- 结合 `registry/tags.yaml` 补充 task-level fallback secondaries
- 输出每个 case 的主 skill/次级候选匹配结果
- 失败时返回非零退出码，便于后续 CI 集成

#### 3. registry 脚本能力增强

更新：

- `scripts/lib_registry.sh`

新增函数：

- `registry_get_list_field`：读取单个 skill 的列表字段（如 `tasks`、`triggers`）
- `tag_registry_list_for_task`：读取某个 task 对应的候选 skill 列表

#### 4. smoke test 与工程入口同步更新

更新：

- `scripts/smoke_test.sh`
  - 改为对 registry 中每个 skill 动态检查：
    - `SKILL.md`
    - `skill.yaml`
    - `agents/openai.yaml`
  - 新增对 `validate_registry.sh` 和 `validate_routing.sh` 存在性检查

- `Makefile`
  - 新增 `make eval-routing`

- `README.md`
  - 新增路由评测命令说明（`scripts/validate_routing.sh` / `make eval-routing`）
  - 将 `skill.yaml` 状态更新为“全量覆盖”

- `docs/architecture.md`
  - 同步说明 `skill.yaml` 全量化和 routing eval 脚本

- `registry/tags.yaml`
  - 新增 `framework-selection`、`interpretation` 标签映射

#### 5. 本轮验证记录

已执行并通过：

- `bash -n scripts/lib_registry.sh scripts/validate_registry.sh scripts/validate_routing.sh scripts/link_skills.sh scripts/smoke_test.sh scripts/bootstrap.sh scripts/provision_stack.sh`
- `bash scripts/validate_registry.sh`
- `bash scripts/validate_routing.sh`
- `make validate-registry`
- `make eval-routing`
- `bash scripts/smoke_test.sh`

关键结果：

- `validate_routing.sh`：`routing eval summary: 8/8 passed`
- `smoke_test.sh`：通过，且已覆盖 10/10 skill 的 `skill.yaml` 完整性检查

### s2f agent 化第三阶段已落地（2026-03-26）

已完成“运行时路由器”落地，使仓库不仅能做离线路由评测，还能对单条用户 query 实时给出主 skill 与次级候选。

#### 1. 新增运行时路由脚本

新增：

- `scripts/route_query.sh`

能力：

- 输入 query（`--query` 或 stdin）
- 可选 task hint（`--task`）
- 读取 `registry/skills.yaml` 与 `registry/tags.yaml`
- 输出：
  - primary skill
  - secondary candidates
  - 命中理由（explicit mention / trigger / task alignment / tag fallback）
- 支持 `--format text|json`
- 支持 `--top-k` 控制返回候选数

#### 2. registry 工具函数补充

更新：

- `scripts/lib_registry.sh`

新增：

- `tag_registry_list_tasks`
  - 用于列举 tags registry 内可用 task，支持运行时 task 自动推断

#### 3. 工程入口与验证链路更新

更新：

- `Makefile`
  - 新增 `make route-query`
  - 用法：`make route-query QUERY='...'`（可选 `TASK='...'`）

- `scripts/smoke_test.sh`
  - 新增 `route_query.sh` 存在性检查
  - 新增运行时路由冒烟检查（验证 `$dnabert2` query 可路由到 `dnabert2` primary）

- `README.md`
  - 新增运行时路由命令示例（text/json 与 Make target）

- `docs/architecture.md`
  - 新增 runtime routing 入口说明

#### 4. 本轮验证记录

已执行并通过：

- `bash -n scripts/lib_registry.sh scripts/validate_registry.sh scripts/validate_routing.sh scripts/route_query.sh scripts/link_skills.sh scripts/smoke_test.sh scripts/bootstrap.sh scripts/provision_stack.sh`
- `make validate-registry`
- `make eval-routing`
- `bash scripts/smoke_test.sh`
- `make route-query QUERY='Help me run AlphaGenome predict_variant with RNA output'`
- `make route-query QUERY='Need variant-effect guidance for REF ALT around chr12 position' TASK='variant-effect'`

关键结果：

- 运行时路由器可返回 primary + secondaries + reasons（text/json）
- `eval-routing` 仍保持 `8/8 passed`
- `smoke_test` 已覆盖运行时路由入口并通过

### s2f agent 化第四阶段已落地（2026-03-26）

已完成“路由逻辑单源化”：评测脚本不再维护独立打分逻辑，改为直接调用运行时路由器。

#### 1. 路由评测改为复用 runtime router

重写：

- `scripts/validate_routing.sh`

当前行为：

- 按 case 读取 `evals/routing/cases.yaml`
- 调用 `scripts/route_query.sh`（`--format json`）执行真实路由
- 从路由结果中提取：
  - primary skill
  - secondary candidates
- 与 `expected_primary_skill` / `expected_secondary_skills` 对比并汇总通过率

效果：

- eval 与 runtime 使用同一套路由逻辑
- 避免“评测通过但线上路由行为不同步”的漂移问题

#### 2. registry 工具函数补充（支持 task 推断）

更新：

- `scripts/lib_registry.sh`

新增：

- `tag_registry_list_tasks`
  - 供 `route_query.sh` 枚举 `registry/tags.yaml` 中定义的 task
  - 支持 query 未显式给 task 时的自动任务推断

#### 3. smoke test 增强

更新：

- `scripts/smoke_test.sh`

新增检查：

- 路由器主 skill 冒烟检查（`$dnabert2` query）
- `validate_routing.sh` 全量路由评测执行检查

#### 4. 文档同步

更新：

- `README.md`
  - 明确 `validate_routing.sh` 会调用 `route_query.sh`
- `docs/architecture.md`
  - 新增“routing eval 复用 runtime router”的架构说明

#### 5. 本轮验证记录

已执行并通过：

- `bash -n scripts/lib_registry.sh scripts/route_query.sh scripts/validate_routing.sh scripts/smoke_test.sh`
- `bash scripts/validate_routing.sh`
- `bash scripts/smoke_test.sh`

关键结果：

- `validate_routing.sh`：`routing eval summary: 8/8 passed`
- `smoke_test.sh`：通过，且已覆盖 route_query + validate_routing 两级路由检查

### s2f agent 完整开发收口（2026-03-26）

在前四阶段基础上，已完成可运行、可校验、可维护的完整 agent runtime 收口。

#### 1. 新增完整运行时入口

新增：

- `scripts/run_agent.sh`

能力：

- 调用 `route_query.sh` 进行主/次 skill 路由
- 读取主 skill 的 `skill.yaml`
- 输出 required inputs、provided inputs、missing inputs
- 自动关联可用 playbook（存在时）
- 输出 constraints、tools 和 next prompt 建议
- 支持 `text/json` 两种输出格式

新增：

- `scripts/agent_console.sh`

能力：

- 本地交互式 console（多轮输入）
- 每次输入调用 `run_agent.sh` 返回结构化决策结果

#### 2. 新增 metadata 完整性校验

新增：

- `scripts/validate_skill_metadata.sh`

校验项：

- 每个 registry skill 是否存在 `skill.yaml`
- `id/path` 与 `registry/skills.yaml` 是否一致
- 关键 scalar/list 字段是否完整且非空
- `status` 是否在允许集合（`active|inactive`）
- task 与 `registry/tags.yaml` 是否可映射

当前状态：

- 10/10 skills metadata 校验通过
- warnings 已清零

#### 3. 补齐 playbook 覆盖

新增：

- `playbooks/fine-tuning/README.md`
- `playbooks/track-prediction/README.md`
- `playbooks/environment-setup/README.md`

当前 playbook 覆盖：

- `variant-effect`
- `embedding`
- `fine-tuning`
- `track-prediction`
- `environment-setup`

#### 4. 任务标签与路由推断增强

更新：

- `registry/tags.yaml`（补齐与 skill tasks 对应的标签映射）
- `scripts/lib_registry.sh`（新增 `yaml_get_scalar_field`、`yaml_get_list_field`、`tag_registry_list_tasks`）
- `scripts/route_query.sh`
  - 增强 task 推断打分
  - 对“低置信路由 + 无 task”场景显式报错，避免静默误路由
  - 保留 task fallback 路由能力

#### 5. 工程入口与 smoke 链路扩展

更新：

- `Makefile`
  - 新增：
    - `make validate-skill-metadata`
    - `make validate-agent`
    - `make run-agent`
    - `make agent-console`

- `scripts/smoke_test.sh`
  - 新增对以下脚本的存在性与行为检查：
    - `run_agent.sh`
    - `agent_console.sh`
    - `validate_skill_metadata.sh`
  - 新增 `run_agent` 主 skill 冒烟校验

- 文档：
  - `README.md`
  - `docs/architecture.md`
  - `agent/README.md`

#### 6. 本轮最终验证

已执行并通过：

- `bash -n scripts/lib_registry.sh scripts/link_skills.sh scripts/validate_registry.sh scripts/validate_skill_metadata.sh scripts/route_query.sh scripts/validate_routing.sh scripts/run_agent.sh scripts/agent_console.sh scripts/smoke_test.sh scripts/bootstrap.sh scripts/provision_stack.sh`
- `make validate-agent`
- `make eval-routing`
- `make run-agent QUERY='Need NTv3 track prediction on hg38 human interval'`
- `bash scripts/run_agent.sh --query 'Need variant-effect guidance for chr12 REF ALT on hg38' --format json`
- `bash scripts/smoke_test.sh`

关键结果：

- `validate-agent` 全链路通过
- `validate-routing`：`8/8 passed`
- `validate_skill_metadata`：`10/10` skills，`0 warning(s)`
- `smoke_test`：通过（覆盖 routing + metadata + runtime agent）

### 本次同步确认（2026-03-26）

已按“完整 agent 交付”口径再次同步并确认：

1. 运行时入口可用：
   - `scripts/route_query.sh`
   - `scripts/run_agent.sh`
   - `scripts/agent_console.sh`

2. 校验入口可用：
   - `scripts/validate_registry.sh`
   - `scripts/validate_skill_metadata.sh`
   - `scripts/validate_routing.sh`
   - `make validate-agent`

3. 验收口径稳定：
   - `make eval-routing` 通过（`8/8 passed`）
   - `bash scripts/smoke_test.sh` 通过

4. 结构层完整：
   - `agent/`、`registry/`、`playbooks/`、`evals/`、`docs/` 已形成完整闭环
   - 10/10 skills 均具备 `SKILL.md + skill.yaml + agents/openai.yaml`

### 目录搬迁评估与规划同步（2026-03-26，已迁移）

该章节规划内容已迁移到 `DEVELOPMENT_PLAN.md`：

- 迁移位置：`从 DEVELOPMENT_PROGRESS.md 迁移的规划内容 / B. 目录搬迁评估与规划同步`
- 维护约定：目录迁移策略后续仅在 `DEVELOPMENT_PLAN.md` 维护

### NT / NTv3 / SegmentNT skills 优化记录（2026-03-26）

已完成 `nucleotide-transformer`、`nucleotide-transformer-v3`、`segment-nt` 三套 skills 的文档与脚本优化，并完成跨 skill 一致性整理（术语、公式、约束表达统一）：

- `nucleotide-transformer` 更新：
  - `nucleotide-transformer/SKILL.md`
  - `nucleotide-transformer/references/model-variants.md`
  - `nucleotide-transformer/references/tokenization-and-limits.md`
  - `nucleotide-transformer/references/usage-patterns.md`
  - `nucleotide-transformer/agents/openai.yaml`
  - 关键内容：
    - 补齐 `attention_maps_to_save` / `max_positions` 使用语义
    - 明确 `1B_agro_nt`、`codon_nt` 的兼容边界
    - 统一 token 术语：
      - `num_tokens_inference`（含 CLS）
      - `num_dna_tokens_excluding_cls`（不含 CLS）

- `nucleotide-transformer-v3` 更新：
  - `nucleotide-transformer-v3/SKILL.md`
  - `nucleotide-transformer-v3/references/model-catalog.md`
  - `nucleotide-transformer-v3/references/pre-vs-post.md`
  - `nucleotide-transformer-v3/references/length-and-memory.md`
  - `nucleotide-transformer-v3/references/setup-and-troubleshooting.md`
  - `nucleotide-transformer-v3/scripts/check_valid_length.py`
  - `nucleotide-transformer-v3/scripts/run_track_prediction.py`
  - `nucleotide-transformer-v3/agents/openai.yaml`
  - 关键内容：
    - 保持 HF 主路径，同时补强 JAX 兼容说明
    - 将长度与输出裁剪逻辑从硬编码改为按配置动态推导：
      - `divisor = 2 ** num_downsamples`
      - `cropped_len` 基于 `keep_target_center_fraction`
    - track 脚本增强了 species 校验、输出头校验、DNA 清洗与元数据字段

- `segment-nt` 更新：
  - `segment-nt/SKILL.md`
  - `segment-nt/references/family-selection.md`
  - `segment-nt/references/inference-patterns.md`
  - `segment-nt/references/constraints.md`
  - 新增：`segment-nt/references/setup-and-troubleshooting.md`
  - `segment-nt/scripts/compute_rescaling_factor.py`
  - `segment-nt/agents/openai.yaml`
  - 关键内容：
    - 明确 SegmentNT / SegmentEnformer / SegmentBorzoi 的 `transform` 路径差异
    - 强化 SegmentNT 的 `N` 限制、`%4` 约束与 `rescaling_factor` 说明
    - `compute_rescaling_factor.py` 新增：
      - `--tokens-exclude-cls`
      - `num_dna_tokens_excluding_cls` 输出（兼容保留旧字段）
      - `%4` 可行性与上下界提示

- 验证记录：
  - `PYTHONPYCACHEPREFIX=/tmp/pycache python3 -m py_compile`
    - 通过：`nucleotide-transformer-v3/scripts/check_valid_length.py`
    - 通过：`nucleotide-transformer-v3/scripts/run_track_prediction.py`
    - 通过：`segment-nt/scripts/compute_rescaling_factor.py`
  - `python3 segment-nt/scripts/compute_rescaling_factor.py --sequence-length-bp 40008`
    - 输出：`num_tokens_inference=6669`
    - 输出：`rescaling_factor=3.2563476562`
  - `bash scripts/smoke_test.sh`
    - 结果：通过（包含 NTv3 与 SegmentNT helper checks）

- Git 记录：
  - commit：`dedac71`
  - message：`refine NT/NTv3/SegmentNT skills and docs; harden helper scripts`
  - push：已推送到 `origin/main`（`e0a02d2..dedac71`）

### DNABERT2 真实调用与 skill 升级（2026-03-25）

已在本机完成一次真实 DNABERT2 区间 embedding 推理，并完成 skill 结构化升级与远程提交：

- 真实推理任务：
  - `species="human"`
  - `assembly="hg38"`
  - 区间：`chr19:6,700,000-6,702,768`（`[start, end)`）
  - 模型：`zhihan1996/DNABERT-2-117M`
- 实际输出：
  - 序列长度：`2768 bp`
  - token 数：`527`（去除 special token 后用于 PCA：`525`）
  - embedding 维度：`768`
  - PCA explained variance ratio：
    - `PC1=0.10104950517416`
    - `PC2=0.031933002173900604`
- 产物文件（已归档）：
  - `output/dnabert2/dnabert2_real_pred/embedding_pca.png`
  - `output/dnabert2/dnabert2_real_pred/run_metadata.json`
  - `output/dnabert2/dnabert2_real_pred/run_dnabert2_real_prediction.py`

- skill 升级内容：
  - 新增脚本：`dnabert2/scripts/embed_interval_plot.py`
  - 更新：`dnabert2/SKILL.md`
  - 更新：`dnabert2/references/inference-quickstart.md`
  - 更新：`dnabert2/references/caveats.md`
  - 更新：`dnabert2/references/setup-and-compatibility.md`
  - 更新：`dnabert2/agents/openai.yaml`
  - 新脚本真实 smoke test 已通过：
    - 任务：`hg38 chr19:6,700,000-6,700,500`
    - 输出：`output/dnabert2/dnabert2_skill_update_smoke/embedding_pca.png`

- Git 记录：
  - commit：`1f89ad1`
  - message：`Update DNABERT2 skill for coordinate embedding workflows`
  - push：已推送到 `origin/main`（`0e53f88..1f89ad1`）

- 本地整理与清理：
  - 已将本次 DNABERT2 相关输出统一整理到 `output/dnabert2/`
  - 已清理本仓库本地 conda 与缓存目录：
    - `.conda-envs/`
    - `.conda-pkgs/`
    - `.pip-cache/`
    - `.hf-cache/`
    - `tmp/`
  - 释放空间约 `7.8 GB`

### Basset skill 更新与实验记录（2026-03-25）

已完成 Basset 资料梳理、skill 构建、仓库接入与验证（本轮以仓库级实验为主，未执行 Torch7 训练实跑）：

- 文档梳理范围：
  - `Readme/Basset_README.md`
  - `Readme/Basset-master/docs/preprocess.md`
  - `Readme/Basset-master/docs/learning.md`
  - `Readme/Basset-master/docs/visualization.md`
  - `Readme/Basset-master/docs/file_specs.md`
  - `Readme/Basset-master/tutorials/*.ipynb` 与 `tutorials/train.md`

- 新增 skill 文件：
  - `basset-workflows/SKILL.md`
  - `basset-workflows/agents/openai.yaml`
  - `basset-workflows/references/setup-and-legacy-caveats.md`
  - `basset-workflows/references/preprocess-and-training.md`
  - `basset-workflows/references/evaluation-and-interpretation.md`
  - `basset-workflows/references/file-formats.md`

- 仓库接入改动：
  - 更新 `README.md`：技能总数、技能表格、示例调用、仓库结构与 scope 说明
  - 更新 `scripts/link_skills.sh`：`AVAILABLE_SKILLS` 新增 `basset-workflows`
  - 更新 `scripts/smoke_test.sh`：`SKILL_IDS` 新增 `basset-workflows`

- 实验与验证记录：
  - `bash scripts/link_skills.sh --list`
    - 结果：可见 `basset-workflows`，技能枚举正确
  - `bash scripts/smoke_test.sh`
    - 结果：通过（含 `basset-workflows SKILL.md` 与 `agents/openai.yaml` 检查）

- Git 记录：
  - commit：`082dde5`
  - message：`Add basset-workflows skill and integrate into repo tooling`
  - push：已推送到 `origin/main`（`e4c1587..082dde5`）

### Evo2 Hosted API 真实调用校验（2026-03-25）

已在本机完成一次真实 Evo2 Hosted API 端到端调用（非 dry-run）：

- 运行环境：
  - conda env：`/usr/local/anaconda3/envs/evo2-full`
  - Python `3.11.13`
  - 关键依赖：`requests`、`numpy`、`matplotlib`
- 任务 1（区间 forward + embeddings + generation）：
  - 基因组：`hg38`
  - 区间：`chr19:6,700,000-6,732,768`
  - forward/embedding：按长序列分块调用 Hosted `forward`，提取并绘制 track
  - generation：先尝试 `evo2-7b`，端点降级时自动回退到 `evo2-40b`
- 任务 2（单位点突变效应）：
  - 位点：`chr12:1,000,000`（1-based）
  - 规则：若 REF=G 则 ALT=T，否则 ALT=G
  - 实测参考碱基为 `T`，因此实际突变为 `T>G`
  - 使用 REF/ALT 的 forward 与 embedding 差分作为 variant-effect proxy，并绘图
- 产物文件：
  - `evo2-inference/results/evo2_chr19_forward_embedding_generation.png`
  - `evo2-inference/results/evo2_chr12_variant_effect.png`
  - `evo2-inference/results/evo2_real_workflow_results.json`
- 结果摘要：
  - 区间 generation 最终成功模型：`evo2-40b`（7B 降级时回退）
  - 位点效应指标：
    - `delta_top1_at_variant=-0.142578125`
    - `delta_emb_norm_at_variant=0.8683944513332645`
- 稳定性观察：
  - Hosted 端点存在瞬时状态波动（例如 `DEGRADED`、`Instance is restarting`、超时）
  - 在 skill 文档中已同步落地重试/回退与长序列降级策略
- 凭证与安全处理：
  - 本文档不记录、不回填任何明文 API key / token
- 凭证仅通过会话环境变量注入，不写入仓库文件

### AlphaGenome 真实调用校验（2026-03-24）

已在本机完成一次真实 `predict_variant` 调用（非 dry-run）：

- 运行环境：
  - Python `3.10.6`
  - `alphagenome 0.6.1`
- 测试位点与规则：
  - 基因组：`hg38`
  - 位点：`chr12:1,000,000`（1-based）
  - 先查询参考碱基，再按规则“若 REF=G 则 ALT=T，否则 ALT=G”构造突变
  - 实测参考碱基为 `T`，因此实际突变为 `T>G`
- 模型请求：
  - 调用：`model.predict_variant(...)`
  - `requested_outputs=[dna_client.OutputType.RNA_SEQ]`
  - `ontology_terms=["UBERON:0001157"]`
  - 输入窗口长度使用受支持长度 `16384 bp`（区间：`chr12:991808-1008192`）
- 返回摘要（ALT-REF）：
  - 输出矩阵形状：`[16384, 3]`
  - `delta_mean=-2.4293947717524134e-05`
  - `delta_abs_mean=4.207091114949435e-05`
  - `delta_max=0.00225830078125`
  - `delta_min=-0.00225830078125`
- 敏感信息处理：
  - 本文档不记录、不回填任何明文 API key
  - 凭证仅用于当次会话调用，后续应使用环境变量或密钥管理方式注入

### NTv3 真实调用校验（2026-03-24）

已在本机完成一次真实 NTv3 post-trained track prediction（非 dry-run）：

- 运行环境：
  - conda env：`/Users/jiaqili/Desktop/s2f-skills/.conda/envs/ntv3-hf`
  - 关键依赖：`transformers 4.57.6`、`huggingface_hub 0.36.2`、`torch 2.2.2`、`numpy 1.26.4`
- 模型与条件：
  - 模型：`InstaDeepAI/NTv3_100M_post`
  - `species="human"`
  - `assembly="hg38"`
  - 区间：`chr19:6,700,000-6,732,768`（长度 `32768`，满足 128 整除）
- 实际输出：
  - `logits` 形状：`(32768, 11)`
  - `bigwig_tracks_logits` 形状：`(12288, 7362)`
  - `bed_tracks_logits` 形状：`(12288, 21, 2)`
  - 预测绘图区间（中间 37.5%）：`chr19:6,710,240-6,722,528`
- 产物文件：
  - `nucleotide-transformer-v3/outputs/ntv3_human_hg38_chr19_6700000_6732768_trackplot.png`
  - `nucleotide-transformer-v3/outputs/ntv3_human_hg38_chr19_6700000_6732768_meta.json`
- 运行观察：
  - 首次运行会下载较大权重文件并存在明显冷启动时间
  - CPU 路径可完成推理，但速度明显慢于 GPU
- 凭证与安全处理：
  - 本文档不记录、不回填任何明文 Hugging Face token
  - 推理脚本改为通过环境变量 `HF_TOKEN` 或参数传入，避免硬编码凭证

### GPN 真实调用校验（2026-03-24）

已在本机完成一次真实 GPN 单位点 `predict_variant` 计算（非 dry-run）：

- 运行环境：
  - conda env：`/usr/local/anaconda3/envs/gpn`
  - `gpn 0.7`
  - `numpy 1.26.4`（为规避 `torch` 与 `numpy 2.x` ABI 兼容问题）
- 模型与输入：
  - 模型：`songlab/gpn-msa-sapiens`
  - 基因组：`hg38`
  - 位点：`chr12:1,000,000`（1-based）
  - 先查询参考碱基，再按规则“若 REF=G 则 ALT=T，否则 ALT=G”构造突变
  - 实测参考碱基为 `T`，因此实际突变为 `T>G`
  - 计算窗口：`512 bp`（`0-based [999743, 1000255)`）
- 实际输出（LLR）：
  - `llr_fwd=0.7417178153991699`
  - `llr_rev=-1.3183715343475342`
  - `llr_mean=-0.28832685947418213`
  - 解释：`LLR<0` 表示模型在该位点更偏向参考碱基（REF）而非突变碱基（ALT）
- 结果文件：
  - `tmp/hg38/gpn_predict_variant_chr12_1000000.json`
- 运行观察与稳定性处理：
  - `gpn.ss.run_vep` 在 CPU 场景受 `fp16/torch_compile` 默认设置影响，存在运行风险
  - Hugging Face 下载在本机出现过 xet range 错误，实测可通过 `HF_HUB_DISABLE_XET=1` 规避
  - 已补充单位点脚本：`gpn-models/references/predict_variant_single_site.py`
  - 已同步更新 GPN skill 文档：`gpn-models/SKILL.md`、`gpn-models/references/loading-and-cli.md`、`gpn-models/references/caveats.md`
- 凭证与安全处理：
  - 本文档不记录、不回填任何明文 API key / token
  - 真实调用过程中使用的凭证均通过会话环境注入，不写入仓库文件

## 当前仓库状态总结

目前仓库已经具备以下能力：

1. 可以让 Codex 直接发现并调用 9 个已完成 skill
2. 可以在新机器上按 stack 拆分方式部署对应软件环境
3. 可以通过 shell 或 Makefile 进行一键部署
4. 可以通过 smoke test 检查部署结果是否完整

## 当前未完成项

以下内容尚未完成或尚未落地验证：

1. `CHM13` skill 还未构建
2. 一键部署流程尚未在全新目标机器上做真实安装验证
3. Evo2 的目标机硬件适配仍依赖部署者提供正确的 `TORCH_INSTALL_CMD`
4. NT / NTv3 的 JAX 安装在不同 CUDA / TPU 环境下仍需要部署者指定合适的 `JAX_INSTALL_CMD`

## 下一步建议

建议按以下顺序继续推进：

1. 在新机器上实际执行一次：
   - `make bootstrap`
   - 或 `./scripts/bootstrap.sh`

2. 如果目标机需要 Evo2：
   - 先验证 `evo2-light`
   - 再决定是否需要 `evo2-full`

3. 完成 `CHM13` skill

4. 视部署反馈补充：
   - `.env.example`
   - `make doctor`
   - Dockerfile
   - Linux / WSL / macOS 的额外部署说明

## 说明

本次整理以开发成果与部署脚本为主。截止 2026-03-25，已在当前机器完成 AlphaGenome、NTv3、GPN、Evo2 Hosted 的真实调用验证，并完成 Basset skill 的文档归纳与仓库级实验校验；其余软件栈仍建议在目标测试机器上完成安装与端到端验证。

## 项目目标

本仓库用于沉淀面向基因组基础模型与相关工具链的 Codex skills，使用户可以通过显式调用 `$skill-name` 或自动触发的方式，直接获得更可靠、更 grounded 的代码生成、参数选择、推理说明与排错支持。

## 当前已完成工作

### 1. 已完成 skills 构建

当前已完成并纳入仓库管理的 skill 共 9 个：

1. `alphagenome-api`
   - 面向 AlphaGenome API 的安装、variant prediction、可视化与边界约束
   - 已补充 `references/quickstart.md`、`references/workflows.md`、`references/caveats.md`

2. `basset-workflows`
   - 面向 legacy Basset Torch7 的 preprocess/train/test/interpretation 工作流
   - 已补充 `references/setup-and-legacy-caveats.md`、`references/preprocess-and-training.md`、`references/evaluation-and-interpretation.md`、`references/file-formats.md`

3. `borzoi-workflows`
   - 面向 Borzoi 官方仓库教程链路（setup、make_data、train_model、score_variants、interpret_sequence、analyze_sv）
   - 已补充 `references/setup-and-env.md`、`references/tutorial-playbooks.md`、`references/variant-and-interpretation.md`

4. `dnabert2`
   - 面向 DNABERT-2 的 embedding 推理、GUE 评测与自定义 CSV 数据集微调
   - 已补充 `references/setup-and-compatibility.md`、`references/inference-quickstart.md`、`references/finetune-workflows.md`、`references/caveats.md`
   - 已补充 `scripts/validate_dataset_csv.py` 与 `scripts/recommend_max_length.py`

5. `evo2-inference`
   - 面向 Evo 2 的本地推理、Hosted API / NIM 选型、checkpoint 选择与硬件约束
   - 已补充 `references/setup-matrix.md`、`references/usage-patterns.md`、`references/deployment-caveats.md`
   - 已补充 Hosted API 可靠性策略：`7b -> 40b` generation 回退、forward ZIP payload 解码、长序列 chunking 与 REF/ALT variant-effect proxy 标注

6. `gpn-models`
   - 面向 GPN / GPN-MSA / PhyloGPN / GPN-Star 的家族选择与 grounded CLI / loading workflow
   - 已补充 `references/framework-selection.md`、`references/loading-and-cli.md`、`references/caveats.md`

7. `nucleotide-transformer`
   - 面向经典 NT v1/v2 的 JAX + Haiku 推理、6-mer tokenization、embeddings 提取与长度约束
   - 已补充 `references/model-variants.md`、`references/usage-patterns.md`、`references/tokenization-and-limits.md`

8. `nucleotide-transformer-v3`
   - 面向 NTv3 的 pre-trained / post-trained 推理、species conditioning、长度整除规则与内存优化
   - 已补充 `references/model-catalog.md`、`references/pre-vs-post.md`、`references/length-and-memory.md`、`references/setup-and-troubleshooting.md`

9. `segment-nt`
   - 面向 SegmentNT / SegmentEnformer / SegmentBorzoi 的 segmentation inference、概率读取与约束处理
   - 已补充 `references/family-selection.md`、`references/inference-patterns.md`、`references/constraints.md`

### 2. 已补充辅助脚本

为减少重复解释和手算，新增了五个 helper scripts：

1. `dnabert2/scripts/validate_dataset_csv.py`
   - 用于检查 `train/dev/test.csv` 的文件存在性、列格式、label 可解析性与序列字符合法性

2. `dnabert2/scripts/recommend_max_length.py`
   - 用于根据单条序列长度或 CSV 统计长度，给出 DNABERT2 `model_max_length` 建议值

3. `nucleotide-transformer-v3/scripts/check_valid_length.py`
   - 用于检查 NTv3 输入长度是否满足 `2^num_downsamples` 的整除要求
   - 可输出最近的合法长度建议

4. `nucleotide-transformer-v3/scripts/run_track_prediction.py`
   - 用于执行 NTv3 post-trained 的区间级 track 预测与绘图
   - 支持 `species/assembly/chrom/start/end`、`HF token`、`device/dtype`、`disable-xet` 等参数

5. `segment-nt/scripts/compute_rescaling_factor.py`
   - 用于根据 token 数或近似 bp 长度计算 SegmentNT 的 `rescaling_factor`
   - 默认按 6-mer + CLS 的近似方式估算

### 3. 已补充项目级说明文档

已新增和更新仓库总览文档：

- `README.md`

目前 README 已覆盖：

- 仓库结构
- 当前 9 个 skills 的用途与调用方式
- `SKILL.md`、`references/`、`scripts/`、`agents/openai.yaml` 的职责
- fresh-machine deployment 流程

### 4. 已补充部署层

为支持在新机器上直接部署和测试，新增了以下部署脚本：

1. `scripts/link_skills.sh`
   - 将 skills 链接或复制到 `~/.codex/skills` 或指定目录

2. `scripts/provision_stack.sh`
   - 在目标机器上创建软件环境
   - 支持的 stack：
     - `alphagenome`
     - `gpn`
     - `nt-jax`
     - `ntv3-hf`
     - `evo2-light`
     - `evo2-full`

3. `scripts/smoke_test.sh`
   - 检查仓库结构、skills 安装路径、helper scripts、可选 Python imports

4. `scripts/bootstrap.sh`
   - 一键部署入口
   - 默认执行：
     - skills 链接
     - `alphagenome` / `gpn` / `nt-jax` 三套核心环境准备
     - smoke test

5. `Makefile`
   - 提供一键命令入口：
     - `make link-skills`
     - `make bootstrap`
     - `make bootstrap-ntv3-hf`
     - `make bootstrap-evo2-light`
     - `make bootstrap-evo2-full`
     - `make smoke`

## 当前验证状态

### skills 结构校验

以下 skills 已通过 `quick_validate.py`：

- `alphagenome-api`
- `basset-workflows`
- `borzoi-workflows`
- `dnabert2`
- `evo2-inference`
- `gpn-models`
- `nucleotide-transformer`
- `nucleotide-transformer-v3`
- `segment-nt`

### helper scripts 校验

已完成的样例验证：

- `validate_dataset_csv.py --data-dir Readme/DNABERT_2-main/sample_data`
  - 返回 `validation=passed`
  - 返回 `total_rows=45`
- `recommend_max_length.py --sequence-length-bp 1000`
  - 输出 `recommended_model_max_length=250`
- `recommend_max_length.py --csv Readme/DNABERT_2-main/sample_data/train.csv`
  - 输出 `recommended_from_max=26`
- `check_valid_length.py 32768`
  - 返回合法
- `check_valid_length.py 33000`
  - 返回不合法，并给出最近合法长度
- `compute_rescaling_factor.py --sequence-length-bp 40008`
  - 输出 `num_tokens_inference=6669`
  - 输出 `rescaling_factor=3.2563476562`

### 部署脚本校验

已完成静态验证：

- `bash -n` 校验以下脚本语法通过：
  - `scripts/link_skills.sh`
  - `scripts/provision_stack.sh`
  - `scripts/smoke_test.sh`
  - `scripts/bootstrap.sh`

- 已验证帮助输出或 dry-run：
  - `link_skills.sh --list`
  - `provision_stack.sh --help`
  - `smoke_test.sh --help`
  - `bootstrap.sh --help`
  - `make help`
  - `make -n bootstrap`
  - `make -n bootstrap-evo2-light`

- repo-level smoke test 已通过
