# Issue tracker: GitHub

本仓的 issue 与规格都在 GitHub issues 里；所有操作走 `gh` CLI。

## 常用操作

- **创建**：`gh issue create --title "..." --body "..."`；多行正文用 heredoc。
- **读取**：`gh issue view <number> --json number,title,body,labels,comments`。
- **列表**：`gh issue list --state open --label <label> --json number,title,labels`。
- **评论**：`gh issue comment <number> --body "..."`。
- **标签**：`gh issue edit <number> --add-label "..."` / `--remove-label "..."`。
- **关闭**：`gh issue close <number> --comment "..."`。
- **子 issue**：`gh issue create --parent <parent> ...`；旧版 `gh` 用
  `gh api --method POST repos/<owner>/<repo>/issues/<parent>/sub_issues -F sub_issue_id=<child-db-id>`，
  或在子 issue 正文顶部写 `Part of #<parent>`。

`gh` 在 clone 内会自动从 `git remote -v` 推断仓库。

## PR

外部 PR 不作为功能请求入口；triage 只针对 issues。GitHub 的 issue / PR 共用编号，
`#42` 可能是 PR：先 `gh pr view 42`，失败再 `gh issue view 42`。

## 规格与标签

- 新功能 / 行为变更先有 issue 或规格，再改代码；issue 是该工作的唯一规格来源。
- 标签含义见 `docs/agents/triage-labels.md`。
- 一个 issue 落地后，把结论与产物路径（ADR / 文档 / 提交）回写到 issue 再关闭。
