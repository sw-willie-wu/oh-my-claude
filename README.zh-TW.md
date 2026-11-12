<p align="center">
  <img src="assets/logo.svg" width="128" height="128" alt="oh-my-claude logo">
</p>

<h1 align="center">oh-my-claude</h1>

<p align="center">
  <strong>看得見現況，留得住經驗。</strong><br>
  Claude Code 的可換主題 statusline 與本機知識庫。
</p>

<p align="center">
  <a href="https://github.com/sw-willie-wu/oh-my-claude/tags"><img src="https://img.shields.io/github/v/tag/sw-willie-wu/oh-my-claude?sort=semver&amp;label=release" alt="最新版本"></a>
  <a href="https://github.com/sw-willie-wu/oh-my-claude/blob/main/LICENSE"><img src="https://img.shields.io/github/license/sw-willie-wu/oh-my-claude" alt="授權"></a>
</p>

---

<p align="center"><a href="README.md">English</a> | 繁體中文</p>

這個 marketplace 為 [Claude Code](https://claude.com/claude-code) 提供三個外掛：**oh-my-status**、**oh-my-knowledge** 與 **oh-my-teams**，每次發版一起更新。

## oh-my-status

Claude Code 的可換主題 statusline。

<p align="center">
  <img src="assets/statusline-fancy.svg" alt="oh-my-status statusline（fancy 版型、tokyonight 主題）：模型、帳號、目錄、分支與 git 變更，以及 context、5 小時、7 天用量條">
</p>

- 9 種主題 × 6 種版型，隨時切換。
- 帳號、context、5 小時與 7 天用量一眼看清。
- 在 Windows 上很省：每次繪製約 2 個行程，git 資訊有快取，`.git` 一變動就會失效重抓。

```
/plugin marketplace add sw-willie-wu/oh-my-claude
/plugin install oh-my-status@oh-my-claude
/reload-plugins
/oh-my-status:setup
```

設定完成後請重開 Claude Code。

## oh-my-knowledge

本機、用 git 版控的知識庫。決策與原因、踩過的雷、慣例、根因這些長期知識集中放在你自己的一個資料夾，專案進度則留在各專案的 auto memory。

- **lookup**：回答疑難類問題前，先搜尋知識庫與該專案的 auto memory。
- **distill**：把這次 session 學到的東西寫進知識頁。
- **handoff**：session 結束時改寫專案進度，再跑 distill。
- **lint**：健檢斷鏈、過期或互相矛盾的頁面與殘留檔。

```
/plugin marketplace add sw-willie-wu/oh-my-claude
/plugin install oh-my-knowledge@oh-my-claude
/reload-plugins
/oh-my-knowledge:setup
```

設定完成後請重開 session。

## oh-my-teams

角色 agent 加一個 lead skill，依你選的審查等級，把一個功能從規格帶到實作。

- **四個等級**：從「直接做」（0）到規格、審過的計畫、審到沒問題為止、每個任務都跑 QA（3）。
- **四個角色**：規格撰寫、實作、審查、QA 測試，各有固定的工作。
- **會收斂的審查迴圈**：每輪換新的 reviewer；修了還是沒有變少時會停下來問你。
- **先查知識庫**：裝了 oh-my-knowledge 時，每個角色開工前先搜尋。

```
/plugin marketplace add sw-willie-wu/oh-my-claude
/plugin install oh-my-teams@oh-my-claude
/reload-plugins
```

不需要設定步驟。用 `/oh-my-teams:lead <要做什麼>` 開始，可以順便指定等級（例如 `level 2`）。在要把工作派給 subagent 時，lead skill 也會自動啟動；沒指定等級的話會問你。

## 文件

文件為英文。

- [Statusline：主題、版型、用法、自訂](docs/statusline.md)
- [安裝 oh-my-status](docs/install.md)
- [升級](docs/upgrading.md)
- [oh-my-knowledge](docs/knowledge.md)
- [oh-my-teams](docs/teams.md)
- [Changelog](CHANGELOG.md)

## 授權

[MIT](LICENSE)
