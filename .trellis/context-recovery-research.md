# Trellis 上下文恢复调研与兼容性方案

> **⚠️ 本文档已被 [`Fusion-Context-Recovery-执行方案.md`](../../Fusion-Context-Recovery-执行方案.md) 取代。**
> 本文是早期调研报告，其中”修改 upstream 文件”的方案已废弃。最终执行方案采用了”upstream 零修改、全新增文件”策略。
> 保留本文仅供历史参考，请勿以此为准实施。

> 目标：在当前 `Fusion Trellis` fork 基础上，增强”长任务 / 上下文重启 / 会话恢复”能力。
> 约束：**优先兼容 upstream Trellis**，避免把恢复能力做成难以合并的大 patch。
> 更新时间：2026-03-26（已归档）

---

## 0. 先说结论

当前这份 Trellis 已经有两类恢复能力：

1. **工作流恢复**
   通过 `.current-task`、`prd.md`、`info.md`、`plan.md`、JSONL 上下文、workspace journal，在新会话里恢复“项目和任务背景”。
2. **会话级恢复**
   通过 `.session-id` + CLI resume 命令，在 Claude/OpenCode/Codex 等平台恢复原会话。

但它还缺一层最关键的能力：

**“任务执行状态”的可机器恢复快照。**

现在的恢复更像：

- 我知道你在做什么
- 我知道你的规范和任务文档
- 我知道怎么回到原会话

但还不够像：

- 我知道你做到哪一 slice 了
- 上次失败在哪一步
- 哪些文件已改、哪些测试挂了
- 如果 provider resume 失效，我还能用文件化状态无损接续

所以我建议你给 Trellis 增加一层 **Fusion Recovery Overlay**：

- 不重写 upstream task/workspace/spec 主模型
- 不把“恢复”绑死到某一个 provider 的 resume 机制
- 以 **task-local 文件状态** 作为第一恢复对象
- 以 **provider session resume** 作为更高优先级但可失效的快捷路径

一句话概括：

**把“恢复”从会话 ID 恢复，升级为“会话 ID + 文件化任务状态 + 轻量 handoff”三层恢复。**

---

## 1. 外部调研结论

### 1.1 Anthropic 的高价值模式

#### A. `reset` 不等于 `compact`

Anthropic 在 2026-03-24 的文章《Harness design for long-running application development》里明确区分了两件事：

- `compaction`：压缩上下文，让同一个 agent 继续跑
- `context reset`：**彻底清空上下文，起一个新 agent，并用结构化 handoff 接棒**

文章的核心判断是：

- 长任务里，单纯 compaction 不一定够
- 模型会出现“context anxiety”或长程漂移
- 这时需要 **clean slate + structured handoff**

对 Trellis 的启发：

- 不能只指望 `/start` 再读一遍上下文
- 也不能只靠 provider 的原生 resume
- 必须有一个 **handoff artifact**，在“换会话 / 换 agent / 换 provider”时继续工作

来源：

- Anthropic, `Harness design for long-running application development`, Published Mar 24, 2026  
  https://www.anthropic.com/engineering/harness-design-long-running-apps

#### B. 通过文件交接，而不是靠大段对话续命

同一篇文章里，Anthropic 提到 generator / evaluator 之间通过文件通信：

- 一个 agent 写文件
- 另一个 agent 读文件并回应
- 由文件承载 contract、状态、交付物

对 Trellis 的启发：

- 你的 `task` 目录天然就是很好的 handoff 容器
- 真正该补的不是“更多 prompt”
- 而是 **更细粒度、更机器友好的任务状态文件**

#### C. 长任务要把状态移出上下文窗口

Anthropic 在 2025-09-29 的《Effective context engineering for AI agents》里给出了更明确的方法论：

- 长任务需要 `compaction`
- 需要 `structured note-taking`
- 需要 `sub-agent architectures`

其中最关键的是：

- agent 应周期性把状态写到上下文窗口外
- 之后在 context reset 后再读回来

文章里点名的例子很贴近本题：

- 维护 `NOTES.md`
- 记录架构决策、未解决 bug、下一步
- reset 之后读自己的 note 继续多小时任务

对 Trellis 的启发：

- `journal` 还不够，它偏 session 回顾
- 需要一个更偏 **当前执行态** 的 `active context / handoff` 文件

来源：

- Anthropic, `Effective context engineering for AI agents`, Published Sep 29, 2025  
  https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents

#### D. Memory tool 的方向是“文件化持久记忆”

Anthropic 在 2025-09-29 的《Managing context on the Claude Developer Platform》里把 context management 拆成两类：

- `context editing`：自动清掉过期 tool 结果
- `memory tool`：通过文件系统把信息持久化到上下文外

这篇文章最值得借鉴的点是：

- 记忆目录是 **文件系统**，不是神秘黑盒
- 记忆由开发者托管
- 适合跨 session 保留项目状态、调试经验、架构决策

对 Trellis 的启发：

- 你不需要引入数据库或向量库才能先把恢复做好
- 先把 **task-local file memory** 做扎实，收益已经很大

来源：

- Claude Blog, `Managing context on the Claude Developer Platform`, Sep 29, 2025  
  https://claude.com/blog/context-management

---

### 1.2 OpenAI 的高价值模式

#### A. 仓库本身就是 system of record

OpenAI 在 2026-02-11 的《Harness engineering: leveraging Codex in an agent-first world》里非常明确：

- 不要把 `AGENTS.md` 当成百科全书
- 应把仓库里的结构化文档目录作为 system of record
- `AGENTS.md` 只做目录 / 导航层
- `plans`、`docs`、`quality docs`、`design docs` 都应入库并版本化

这和你当前 Fusion Trellis 的方向非常一致：

- `prd.md`
- `info.md`
- `plan.md`
- `.trellis/spec/`
- `journal`

说明你的 fork 路线没有跑偏。

但 OpenAI 还多做了一步：

- `execution plans` 被当成第一类 artifact
- 计划中包含进度、验证命令、决策日志

对 Trellis 的启发：

- 你已经有 `plan.md`
- 下一步不是再发明新层，而是给 `plan.md` 配一个 **plan progress state**

来源：

- OpenAI, `Harness engineering: leveraging Codex in an agent-first world`, Feb 11, 2026  
  https://openai.com/index/harness-engineering/

#### B. 让“外部状态”替代“全塞进 prompt”

OpenAI 在 2026-03-11 的《From model to agent: Equipping the Responses API with a computer environment》里强调：

- 当上下文窗口逼近上限时，应该做 `compaction`
- 文件系统、数据库、容器状态本身都是 agent 的 working context
- 反模式是把所有输入直接塞进 prompt

对 Trellis 的启发：

- 恢复包不应该是“把 journal 全读一遍”
- 应该是：
  - 一份短 `handoff.md`
  - 一份结构化 `recovery.json`
  - 若干被引用的关键文件路径

也就是：

**把“全部上下文”改成“状态索引 + 按需展开”。**

来源：

- OpenAI, `From model to agent: Equipping the Responses API with a computer environment`, Mar 11, 2026  
  https://openai.com/index/equip-responses-api-computer-environment/

#### C. 状态化 API 的价值在于“链式恢复”

OpenAI 官方 `Conversation state` 文档给了两种恢复状态的方式：

- `conversation`
- `previous_response_id`

并且明确说明：

- Responses API 是 stateful 的
- Conversations 可以跨 session / device / job 保持状态

对 Trellis 的启发：

- provider resume 值得保留，而且要继续抽象在 `CLIAdapter`
- 但它只能作为 **第一恢复层**
- 因为不同 provider 的持久性、TTL、可移植性并不一致

来源：

- OpenAI Docs, `Conversation state`  
  https://developers.openai.com/api/docs/guides/conversation-state

#### D. 长任务能跑住，靠的是 durable project memory

OpenAI Developers 的《Run long horizon tasks with Codex》讲得更直接：

- 长任务不是一个超大 prompt
- 而是 agent loop + externalized state
- 把 spec、plan、constraints、status 写进 markdown 文件
- 让 Codex 重复回看这些 durable project memory

这篇文章和 Trellis 的结合度极高。

它本质上支持以下判断：

- `Prompt.md` 类似 Trellis 的 `prd.md`
- `Plan.md` 类似你 Fusion 的 `plan.md`
- 但还应该有一个 `status` / `progress` 层

来源：

- OpenAI Developers, `Run long horizon tasks with Codex`  
  https://developers.openai.com/blog/run-long-horizon-tasks-with-codex

---

### 1.3 Cline 的高价值模式

Cline 的 `Memory Bank` 没有复杂基础设施，但很实用。

它把跨 session 记忆拆成 6 类 markdown：

- `projectbrief.md`
- `productContext.md`
- `activeContext.md`
- `systemPatterns.md`
- `techContext.md`
- `progress.md`

其中最值得借鉴的是：

- `activeContext.md`：当前焦点、最近变化、下一步
- `progress.md`：已完成、待完成、已知问题

这恰好补的是 Trellis 当前最缺的那一层：

- 不是总背景
- 不是历史 journal
- 而是 **当前执行态**

来源：

- Cline Docs, `Memory Bank`  
  https://docs.cline.bot/features/memory-bank

---

## 2. 从这些公开方案里提炼出的共性模式

这些方案表面实现不同，但底层共性非常稳定：

### 2.1 三种状态必须分层

一个成熟的恢复系统，至少要区分三类状态：

1. **项目长期知识**
   架构、规范、系统边界、约束
2. **任务目标与计划**
   当前 task 要做什么、怎么验收、怎么执行
3. **当前执行态**
   已做到了哪一步、最新阻塞、上次失败点、下一步

Trellis 现在前两层已经不错，第三层偏弱。

### 2.2 恢复对象应该是“文件化状态”，不是整段 transcript

长任务恢复时，最好优先恢复：

- 已验证结论
- 决策
- 下一步
- 关键文件列表
- 错误摘要

而不是先恢复：

- 完整对话
- 全量工具输出
- 大量重复搜索结果

### 2.3 `compact` 和 `reset + handoff` 要并存

- `compact` 适合同一会话继续跑
- `reset + handoff` 适合上下文已经污染、agent 漂移、会话断开、换平台

### 2.4 恢复要优先“索引化”

最好的恢复包不是全文，而是：

- 一段短摘要
- 一份结构化状态
- 一组关键文件引用

### 2.5 Provider resume 是快捷通道，不是唯一真相

因为：

- 有的平台支持 `resume`
- 有的平台只支持继续最近一次
- 有的平台 session ID 不是创建时可控
- 有的平台可能会过期或跨设备不稳定

所以真正可靠的是 **repo 内持久化状态**。

---

## 3. 当前 Fusion Trellis 的现状评估

### 3.1 已有优势

当前这份仓库已经具备很强的基础：

#### A. 任务目录已经是天然恢复容器

你现在每个 task 已经有：

- `prd.md`
- `info.md`（Fusion）
- `plan.md`（Fusion）
- `implement.jsonl`
- `check.jsonl`
- `debug.jsonl`
- `task.json`

这比很多工具成熟得多。

#### B. `session-start` 已能自动恢复大盘上下文

当前 hook 会注入：

- current state
- workflow
- spec index
- start instructions
- task status

这意味着你已经有了“冷启动恢复”的骨架。

#### C. multi-agent 已有 session resume abstraction

你已经做了跨平台适配：

- Claude：`--session-id` / `--resume`
- OpenCode：日志提取 `ses_xxx` / `--session`
- Codex / Gemini / Qoder 也已预留

这非常好，说明“会话恢复”这层已经抽象出来了。

#### D. `journal` 已承担 session 归档

`add_session.py` 目前已经做到了：

- session 归档
- index 更新
- `.trellis/workspace` + `.trellis/tasks` 自动 commit

这让“历史回顾”可追溯。

---

### 3.2 当前短板

#### A. 缺少 task 的“活跃执行态”

现在新会话能恢复：

- 在做哪个任务
- 任务的 PRD / 规范 / 计划

但恢复不了这些更关键的信息：

- `plan.md` 做到哪一 slice
- 上次 red/green/refactor 卡在哪
- 哪个测试命令最近失败
- 哪些文件是当前工作集
- 下一步到底建议做什么

#### B. `journal` 更像历史日志，不是执行状态

`journal` 的定位是对的，但它不是给 agent 快速接管当前 task 用的。

它的问题不是“没用”，而是：

- 时间跨度大
- 混入太多 session 回顾信息
- 不适合每次恢复都整段加载

#### C. provider resume 失效后，缺少稳态 fallback

如果 `.session-id` 对应的会话不可恢复，当前 fallback 主要还是：

- 再跑一次 start
- 再读 task 文件

但这不足以把 agent 恢复到“接近断点续跑”的状态。

#### D. Fusion 四件套没有显式 checkpoint 层

你现在最强的工作流是：

- `brainstorm-plus`
- `write-task-plan`
- `execute-plan-tdd`
- `harvest-learnings`

但这里面还没有统一的“状态快照”落盘动作。

也就是说：

- 你有计划
- 你有执行
- 你有沉淀

但缺少：

- **执行中的 checkpoint**

---

## 4. 方案目标

我要的不是“做一个很炫的记忆系统”，而是做一个 **易维护、可合并、可退化、跨平台** 的恢复层。

### 4.1 设计目标

1. **兼容 upstream**
   尽量不改 upstream 核心目录结构和原生命令语义。
2. **平台无关**
   Claude/OpenCode/Codex 都能用，不能只靠某一家 provider 的 resume。
3. **task-local**
   恢复数据尽量放在 task 目录内，跟着任务走，便于归档、review、提交。
4. **双格式**
   既有机器可读的 JSON，也有人和 agent 都易读的 Markdown。
5. **按需注入**
   恢复时先注入短摘要，不把全部历史塞进上下文。
6. **渐进增强**
   先做显式恢复，再做自动恢复，再考虑自动 compaction/handoff。

---

## 5. 推荐架构：Fusion Recovery Overlay

### 5.1 不改 upstream 主结构，新增 task-local 命名空间

推荐在每个 task 下新增一个 namespaced 目录：

```text
.trellis/tasks/<task>/
├── prd.md
├── info.md
├── plan.md
├── task.json
└── .fusion/
    ├── recovery.json
    ├── handoff.md
    ├── events.jsonl
    ├── sessions.json
    └── artifacts/
```

这样做的好处：

- 不污染 upstream 既有文件名
- 未来 upstream 如果引入原生恢复层，迁移简单
- 你的 fork 能把所有增强局限在 `.fusion/`

### 5.2 四个核心文件的职责

#### `recovery.json`

机器可读的当前执行态。

建议字段：

```json
{
  "version": 1,
  "updated_at": "2026-03-26T13:20:00+08:00",
  "source": "execute-plan-tdd",
  "phase": "implement",
  "status": "in_progress",
  "task": {
    "dir": "03-26-context-recovery",
    "title": "上下文恢复增强"
  },
  "objective": "为当前 fork 增强跨会话恢复能力",
  "plan_progress": {
    "current_slice": "S3",
    "completed_slices": ["S1", "S2"],
    "last_completed_step": "S3.red",
    "next_recommended_action": "修复 failing test 后进入 green"
  },
  "working_set": {
    "files": [
      ".trellis/scripts/get_context.py",
      ".claude/hooks/session-start.py"
    ],
    "recent_commands": [
      "pytest packages/cli/test/test_resume.py"
    ]
  },
  "validation": {
    "last_status": "failed",
    "last_summary": "1 个测试失败：resume mode 断言不匹配"
  },
  "blockers": [
    "需要决定是否在 SessionStart 默认自动注入恢复摘要"
  ],
  "provider_sessions": {
    "claude": "uuid",
    "opencode": "ses_xxx"
  }
}
```

#### `handoff.md`

给下一次会话 / 下一个 agent 看的短摘要。

建议固定成 6 段：

1. 当前目标
2. 已完成
3. 当前阻塞
4. 当前工作集文件
5. 已验证 / 未验证
6. 下一步

这个文件应该短，最好控制在 100-200 行以内。

#### `events.jsonl`

append-only 事件流，用于审计和回放，不直接整段注入上下文。

记录事件类型即可：

- `checkpoint_written`
- `validation_failed`
- `slice_completed`
- `handoff_updated`
- `resume_attempted`

#### `sessions.json`

记录 provider 相关的 session 元数据，避免只把 session ID 孤零零放在 worktree 根目录：

- provider
- session_id
- worktree_path
- created_at
- last_seen_at
- status

这样以后即使换 worktree 展示逻辑，也能统一从 task-local 元数据回看。

---

## 6. 三层恢复模型

这是我最推荐你采用的核心模型。

### 第一层：Exact Resume

适用场景：

- provider 原生 resume 可用
- 会话没过期
- 你就想“原地接上”

来源：

- 当前 `.session-id`
- `CLIAdapter.build_resume_command()`

保持不变，只需要把元数据再同步进 `sessions.json`。

### 第二层：Semantic Resume

适用场景：

- provider resume 不可用
- 要换平台
- 会话窗口已经污染
- 想 clean restart 但不想丢状态

恢复输入：

- `recovery.json`
- `handoff.md`
- `plan.md`
- `task.json`
- 当前 git 状态 / diff 摘要

这是这次方案要重点补强的层。

### 第三层：Cold Resume

适用场景：

- 任务很久没碰
- 没有 checkpoint
- 只有基础 task 文档

恢复输入：

- `prd.md`
- `info.md`
- `plan.md`
- spec index
- workflow

这个你现在已经有了。

---

## 7. 具体怎么赋能到当前 Trellis

### 7.1 第一阶段：低风险落地

这一阶段尽量不碰 upstream 核心 hook 逻辑。

#### 建议新增

1. `.trellis/scripts/common/recovery.py`
   统一处理 recovery 文件读写。
2. `.trellis/scripts/task.py checkpoint`
   显式写入 `recovery.json` + `handoff.md`。
3. `.trellis/scripts/get_context.py --mode resume`
   输出简洁恢复包。
4. `.claude/commands/fusion/resume-context.md`
5. `.agents/skills/resume-context/SKILL.md`

#### 第一阶段的工作方式

- `brainstorm-plus` 结束后写 checkpoint
- `write-task-plan` 结束后写 checkpoint
- `execute-plan-tdd` 每完成一个 slice 写 checkpoint
- `systematic-debugging` 每次定位出根因后写 checkpoint
- `review-with-agents` 在 review 结论后写 checkpoint

优点：

- 基本不碰 upstream native commands
- 只增强 Fusion 自己的链路
- 适合你的 fork 当前定位

### 7.2 第二阶段：中风险增强

在 `session-start` hook 中增加一个**可选**的恢复摘要注入段。

做法建议：

- 只在存在 active task 且存在 `.fusion/handoff.md` 时注入
- 只注入短摘要，不注入 `events.jsonl`
- 挂配置开关，例如：

```yaml
recovery:
  auto_inject: true
  inject_mode: handoff_only
```

需要轻改的文件：

- `.claude/hooks/session-start.py`
- `.codex/hooks/session-start.py`

注意：

- 这一步是增强，不是第一阶段必做
- 因为它会增加一点 upstream merge 成本

### 7.3 第三阶段：高价值自动化

把 checkpoint 机制嵌入 multi-agent / long-running loop。

建议点位：

- `.trellis/scripts/multi_agent/start.py`
  启动时写 session 元数据
- `status.py` / `status_display.py`
  展示最近 handoff 与下一步
- `add_session.py`
  记录 session 时可自动引用最新 `handoff.md`

这一步完成后，你的恢复体系就会比较完整：

- 会话能 resume
- 任务能 cold start
- 长任务能 semantic resume

---

## 8. 推荐的最小实现范围

如果你只做一版 MVP，我建议范围收敛到下面这些：

### 必做

1. 新增 task-local `.fusion/`
2. 新增 `recovery.json`
3. 新增 `handoff.md`
4. 新增 `task.py checkpoint`
5. 新增 `get_context.py --mode resume`
6. 新增 `/fusion:resume-context` 和 `$resume-context`

### 可选但很值

1. `execute-plan-tdd` 每个 slice 自动调用 checkpoint
2. `systematic-debugging` 在 root cause 确认后自动写 checkpoint

### 暂缓

1. 自动截断 / 自动 compaction
2. transcript 全量持久化
3. 向量检索 / 数据库化记忆
4. 大改 upstream 原生命令

---

## 9. 为什么我不建议你一上来就做“全量对话持久化”

因为它很容易把项目带偏。

### 9.1 成本高

- 体积大
- 隐私风险高
- 读取成本高
- 真正恢复时也未必需要

### 9.2 信噪比差

原始 transcript 往往充满：

- 重复工具输出
- 临时探索
- 错误方向
- 已失效假设

恢复时更需要的是“净化后的状态”。

### 9.3 与 Trellis 当前气质不一致

Trellis 现在的优势正是：

- 文件化
- 结构化
- 可审计
- 可 Git 化

继续沿这个方向做，比引入一坨 opaque 会话存档更适合你。

---

## 10. 与 upstream 兼容的关键策略

这部分是最重要的。

### 10.1 用 namespace 隔离自定义

建议所有新增都走：

- `.fusion/`
- `/fusion:*`
- `.agents/skills/<custom-skill>`

不要直接篡改 upstream 原有 task schema 语义。

### 10.2 优先新增，不优先改写

优先级建议：

1. 新增脚本
2. 新增 command / skill
3. 新增 config key
4. 最后才改 hook

### 10.3 让 recovery 成为 overlay，不是 fork core

可以把这套恢复能力视为第 7 个 Fusion 能力，和现有 6 个能力同级：

- `resume-context`

甚至未来可以继续通过 `install-fusion.sh` 安装到别的 Trellis 项目。

### 10.4 不要求 upstream 理解你的恢复文件

最好的兼容性，就是：

- upstream 不认识 `.fusion/` 也没关系
- upstream update 不需要特别知道 recovery schema
- 你的增强仍能独立工作

---

## 11. 建议的实施顺序

### Phase 1

- 加 `.fusion/recovery.json`
- 加 `.fusion/handoff.md`
- 加 `task.py checkpoint`
- 加 `get_context.py --mode resume`
- 加 `/fusion:resume-context`

### Phase 2

- `execute-plan-tdd` / `systematic-debugging` 自动 checkpoint
- `multi_agent/start.py` 同步 `sessions.json`

### Phase 3

- `session-start` 可选自动注入 handoff
- `record-session` 自动吸收 handoff 摘要

### Phase 4

- 研究是否需要自动 compaction / auto handoff
- 研究是否需要 transcript pointer，而不是 transcript 本体

---

## 12. 我对你这个项目的最终建议

### 核心判断

你现在这份 Fusion Trellis 已经具备了：

- 文档化任务层
- 计划化执行层
- provider resume 层
- journal 历史层

真正值得补的，不是再加一个大而全的“记忆系统”，而是补齐中间缺失的那层：

**task execution state。**

### 最合理的方案

把恢复能力做成一个 **Fusion Recovery Overlay**：

- task-local
- file-based
- provider-agnostic
- namespaced
- incremental

### 一句话版本

**保留你当前 Trellis 的 task/spec/journal 架构，不去推翻它；只在 task 内增加 `.fusion` 恢复层，把“计划执行进度、阻塞、工作集、下一步”结构化落盘。**

这条路线最稳，也最适合你后续继续跟 upstream。

---

## 13. 参考来源

- Anthropic, `Harness design for long-running application development`  
  https://www.anthropic.com/engineering/harness-design-long-running-apps
- Anthropic, `Effective context engineering for AI agents`  
  https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents
- Claude Blog, `Managing context on the Claude Developer Platform`  
  https://claude.com/blog/context-management
- OpenAI, `Harness engineering: leveraging Codex in an agent-first world`  
  https://openai.com/index/harness-engineering/
- OpenAI, `From model to agent: Equipping the Responses API with a computer environment`  
  https://openai.com/index/equip-responses-api-computer-environment/
- OpenAI Developers, `Run long horizon tasks with Codex`  
  https://developers.openai.com/blog/run-long-horizon-tasks-with-codex
- OpenAI Docs, `Conversation state`  
  https://developers.openai.com/api/docs/guides/conversation-state
- OpenAI Docs, `Reasoning best practices`  
  https://developers.openai.com/api/docs/guides/reasoning-best-practices
- Cline Docs, `Memory Bank`  
  https://docs.cline.bot/features/memory-bank
