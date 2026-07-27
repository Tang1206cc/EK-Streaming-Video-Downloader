import { createContext, type ReactNode, useContext, useEffect, useMemo, useState } from "react";

export type AppLanguage = "zh-Hans" | "zh-Hant" | "en" | "ja";

type Translation = {
  "zh-Hant": string;
  en: string;
  ja: string;
};

const translations: Record<string, Translation> = {
  "作者": { "zh-Hant": "作者", en: "Author", ja: "作者" },
  "主页": { "zh-Hant": "主頁", en: "Homepage", ja: "ホームページ" },
  "关于": { "zh-Hant": "關於", en: "About", ja: "このアプリについて" },
  "实现主流网站视频快速按需下载，本工具仅作学习与非盈利用途，请勿恶意利用其侵犯他人/组织的合法权益，用户行为与本工具作者无关。": { "zh-Hant": "快速按需下載主流網站影片。本工具僅供學習與非營利用途，請勿惡意使用以侵害他人或組織的合法權益。使用者的行為與本工具作者無關。", en: "Quickly download videos from major platforms in the format you need. This tool is for learning and non-commercial use only. Do not use it to infringe the lawful rights of any person or organization. The author is not responsible for user conduct.", ja: "主要なプラットフォームから必要な形式でビデオをすばやくダウンロードします。このツールは学習および非営利目的のみを目的としています。個人または組織の法的権利を侵害するために使用しないでください。作者はユーザーの行為に対して責任を負いません。" },
  "打开偏好设置": { "zh-Hant": "開啟偏好設定", en: "Open Preferences", ja: "環境設定を開く" },
  "偏好设置": { "zh-Hant": "偏好設定", en: "Preferences", ja: "環境設定" },
  "关闭关于窗口": { "zh-Hant": "關閉關於視窗", en: "Close About window", ja: "「バージョン情報」ウィンドウを閉じる" },
  "关闭环境配置": { "zh-Hant": "關閉環境設定", en: "Close environment setup", ja: "環境セットアップを閉じる" },
  "关闭下载列表": { "zh-Hant": "關閉下載清單", en: "Close download list", ja: "ダウンロードリストを閉じる" },
  "链接解析": { "zh-Hant": "連結解析", en: "Link parsing", ja: "リンク解析" },
  "粘贴视频页分享链接": { "zh-Hant": "貼上影片頁面的分享連結", en: "Paste a shared video-page link", ja: "共有ビデオページのリンクを貼り付けます" },
  "⚠️配置所需环境": { "zh-Hant": "⚠️設定所需環境", en: "⚠️ Set Up Requirements", ja: "⚠️ 要件を設定する" },
  "配置所需环境": { "zh-Hant": "設定所需環境", en: "Set Up Requirements", ja: "要件の設定" },
  "初次使用务必点击，否则可能无法正常使用": { "zh-Hant": "首次使用務必點選，否則可能無法正常使用", en: "Required before first use to ensure the app works correctly", ja: "アプリが正しく動作することを確認するために、初めて使用する前に必要です" },
  "查看目前支持平台": { "zh-Hant": "查看目前支援的平台", en: "View Supported Platforms", ja: "サポートされているプラットフォームを表示する" },
  "目前支持平台": { "zh-Hant": "目前支援的平台", en: "Supported Platforms", ja: "サポートされているプラットフォーム" },
  "下载列表": { "zh-Hant": "下載清單", en: "Downloads", ja: "ダウンロード" },
  "填入示例": { "zh-Hant": "填入範例", en: "Use Example", ja: "使用例" },
  "解析": { "zh-Hant": "解析", en: "Parse", ja: "解析" },
  "解析中": { "zh-Hant": "解析中", en: "Parsing", ja: "解析中" },
  "正在识别链接": { "zh-Hant": "正在識別連結", en: "Identifying link", ja: "リンクの識別" },
  "正在访问平台页面": { "zh-Hant": "正在連線平台頁面", en: "Opening platform page", ja: "プラットフォームページを開く" },
  "正在读取视频信息": { "zh-Hant": "正在讀取影片資訊", en: "Reading video details", ja: "ビデオの詳細を読む" },
  "解析结果": { "zh-Hant": "解析結果", en: "Parsed video", ja: "解析されたビデオ" },
  "封面预览": { "zh-Hant": "封面預覽", en: " cover preview", ja: " カバープレビュー" },
  "下载封面": { "zh-Hant": "下載封面", en: "Download Cover", ja: "カバーをダウンロード" },
  "下载后提示🔔": { "zh-Hant": "下載完成後提示🔔", en: "Completion sound 🔔", ja: "完了音🔔" },
  "注意：抖音平台合集视频的列表暂时无法完整呈现，请自行分集解析。": { "zh-Hant": "注意：抖音合集的影片清單目前無法完整顯示，請逐集解析。", en: "Note: Douyin collection lists cannot currently be displayed in full. Please parse each episode separately.", ja: "注: 現在、Douyin コレクションのリストをすべて表示することはできません。各エピソードを個別に解析してください。" },
  "授权状态：": { "zh-Hant": "授權狀態：", en: "Authorization: ", ja: "認可: " },
  "检查中": { "zh-Hant": "檢查中", en: "Checking", ja: "チェック中" },
  "已授权": { "zh-Hant": "已授權", en: "Authorized", ja: "認可された" },
  "未授权": { "zh-Hant": "未授權", en: "Not authorized", ja: "許可されていません" },
  "下载过程中腾讯可能会要求登录微信，此登录与本工具无关。": { "zh-Hant": "下載過程中騰訊可能會要求登入微信，此登入由騰訊提供，與本工具無關。", en: "Tencent may request a WeChat sign-in during download. This sign-in is provided by Tencent and is independent of this app.", ja: "Tencent は、ダウンロード中に WeChat へのサインインを要求する場合があります。このサインインは Tencent によって提供され、このアプリとは独立しています。" },
  "清理当前授权": { "zh-Hant": "清除目前授權", en: "Clear Authorization", ja: "承認のクリア" },
  "正在清理": { "zh-Hant": "正在清除", en: "Clearing", ja: "クリアリング" },
  "发布日期": { "zh-Hant": "發佈日期", en: "Published", ja: "発行済み" },
  "视频时长": { "zh-Hant": "影片時長", en: "Duration", ja: "期間" },
  "下载信息": { "zh-Hant": "下載資訊", en: "Download Info", ja: "ダウンロード情報" },
  "登录后获取": { "zh-Hant": "登入後取得", en: "Available after sign-in", ja: "サインイン後に利用可能" },
  "预估大小未知": { "zh-Hant": "預估大小未知", en: "Estimated size unavailable", ja: "推定サイズがありません" },
  "完整": { "zh-Hant": "完整", en: "Full", ja: "フル" },
  "音频": { "zh-Hant": "音訊", en: "Audio", ja: "オーディオ" },
  "视频": { "zh-Hant": "影片", en: "Video", ja: "ビデオ" },
  "分开": { "zh-Hant": "分開", en: "Separate", ja: "別個" },
  "完整视频": { "zh-Hant": "完整影片", en: "Complete Video", ja: "完全な動画" },
  "仅音频": { "zh-Hant": "僅音訊", en: "Audio Only", ja: "音声のみ" },
  "仅视频": { "zh-Hant": "僅影片", en: "Video Only", ja: "動画のみ" },
  "音视频分开": { "zh-Hant": "音影分開", en: "Separate Audio & Video", ja: "音声と動画を分離" },
  "当前下载模式：": { "zh-Hant": "目前下載模式：", en: "Current download mode: ", ja: "現在のダウンロード モード: " },
  "下载模式": { "zh-Hant": "下載模式", en: "Download mode", ja: "ダウンロードモード" },
  "下载": { "zh-Hant": "下載", en: "Download", ja: "ダウンロード" },
  "下载目录": { "zh-Hant": "下載位置", en: "Save to", ja: "保存先" },
  "下载目录选择": { "zh-Hant": "選擇下載位置", en: "Choose download location", ja: "ダウンロード場所の選択" },
  "系统下载文件夹": { "zh-Hant": "系統下載資料夾", en: "System Downloads folder", ja: "システムダウンロードフォルダー" },
  "选择": { "zh-Hant": "選擇", en: "Choose", ja: "選択してください" },
  "恢复默认": { "zh-Hant": "恢復預設", en: "Use Default", ja: "デフォルトを使用" },
  "下载进度": { "zh-Hant": "下載進度", en: "Download progress", ja: "ダウンロードの進行状況" },
  "等待解析链接": { "zh-Hant": "等待解析連結", en: "Paste a link to get started", ja: "リンクを貼り付けて開始してください" },
  "空状态": { "zh-Hant": "空白狀態", en: "Empty state", ja: "空の状態" },
  "知道了": { "zh-Hant": "知道了", en: "Got It", ja: "わかりました" },
  "点击可跳转 ↗": { "zh-Hant": "點選即可前往 ↗", en: "Open link ↗", ja: "リンクを開く ↗" },
  "邮箱同号": { "zh-Hant": "電子郵件同號", en: "same number for email", ja: "メールでも同じ番号" },
  "作者与版权信息": { "zh-Hant": "作者與版權資訊", en: " author and copyright information", ja: " 著者と著作権情報" },
  "合集选择：已选": { "zh-Hant": "合集選擇：已選", en: "Collection: ", ja: "コレクション: " },
  "集": { "zh-Hant": "集", en: " episodes", ja: " 話" },
  "第": { "zh-Hant": "第", en: "Episode ", ja: "第" },
  "未选择": { "zh-Hant": "未選擇", en: "None selected", ja: "何も選択されていません" },
  "勾选全部": { "zh-Hant": "全選", en: "Select All", ja: "すべて選択" },
  "取消勾选": { "zh-Hant": "取消全選", en: "Clear Selection", ja: "選択をクリア" },
  "合集视频选择": { "zh-Hant": "選擇合集影片", en: "Select collection videos", ja: "コレクションビデオを選択" },
  "确定": { "zh-Hant": "確定", en: "Confirm", ja: "確認" },
  "下载任务分类": { "zh-Hant": "下載任務分類", en: "Download categories", ja: "ダウンロードカテゴリ" },
  "下载中": { "zh-Hant": "下載中", en: "Active", ja: "アクティブ" },
  "已完成": { "zh-Hant": "已完成", en: "Completed", ja: "完了" },
  "全部暂停": { "zh-Hant": "全部暫停", en: "Pause All", ja: "すべて一時停止" },
  "全部开始": { "zh-Hant": "全部開始", en: "Start All", ja: "すべて開始" },
  "全部删除": { "zh-Hant": "全部刪除", en: "Delete All", ja: "すべて削除" },
  "暂无已完成任务": { "zh-Hant": "尚無已完成的任務", en: "No completed downloads", ja: "完了したダウンロードはありません" },
  "暂无下载任务": { "zh-Hant": "尚無下載任務", en: "No downloads", ja: "ダウンロードなし" },
  "合集": { "zh-Hant": "合集", en: "Collection", ja: "コレクション" },
  "暂停": { "zh-Hant": "暫停", en: "Pause", ja: "一時停止" },
  "开始": { "zh-Hant": "開始", en: "Start", ja: "開始" },
  "删除": { "zh-Hant": "刪除", en: "Delete", ja: "削除" },
  "等待中": { "zh-Hant": "等待中", en: "Queued", ja: "キューに入れられました" },
  "已暂停": { "zh-Hant": "已暫停", en: "Paused", ja: "一時停止中" },
  "准备中": { "zh-Hant": "準備中", en: "Preparing", ja: "準備中" },
  "失败": { "zh-Hant": "失敗", en: "Failed", ja: "失敗" },
  "待开始": { "zh-Hant": "待開始", en: "Not started", ja: "開始されていません" },
  "运行环境": { "zh-Hant": "執行環境", en: "Runtime Environment", ja: "実行環境" },
  "本功能会检查视频解析、下载及媒体处理所需组件。应用会优先复用设备上已有工具；缺失时仅安装应用专用副本，无需安装 Xcode、Node.js 或 Homebrew，也不会改动已有工具。": { "zh-Hant": "此功能會檢查影片解析、下載與媒體處理所需的元件。應用程式會優先使用裝置上現有的工具；如有缺少，僅會安裝應用程式專用副本，無需安裝 Xcode、Node.js 或 Homebrew，也不會改動現有工具。", en: "This checks the components required for video parsing, downloading, and media processing. Existing tools are reused whenever possible; missing components are installed only for this app. Xcode, Node.js, and Homebrew are not required, and existing tools are never modified.", ja: "これにより、ビデオの解析、ダウンロード、メディア処理に必要なコンポーネントがチェックされます。既存のツールは可能な限り再利用されます。不足しているコンポーネントはこのアプリに対してのみインストールされます。 Xcode、Node.js、Homebrew は必要なく、既存のツールが変更されることはありません。" },
  "本功能会检查视频解析、下载及媒体处理所需组件。应用已随附可直接使用的基础组件，也会复用设备上的现有工具；联网更新为可选操作，无需安装 Xcode、Node.js 或 Homebrew。": { "zh-Hant": "此功能會檢查影片解析、下載與媒體處理所需的元件。應用程式已隨附可直接使用的基礎元件，也會使用裝置上的現有工具；連線更新為選用操作，無需安裝 Xcode、Node.js 或 Homebrew。", en: "This checks the components required for video parsing, downloading, and media processing. Ready-to-use baseline components are included, existing device tools can also be reused, and online updates are optional. Xcode, Node.js, and Homebrew are not required.", ja: "これにより、ビデオの解析、ダウンロード、メディア処理に必要なコンポーネントがチェックされます。すぐに使用できるベースライン コンポーネントが含まれており、既存のデバイス ツールも再利用でき、オンライン アップデートはオプションです。 Xcode、Node.js、および Homebrew は必要ありません。" },
  "待检查": { "zh-Hant": "待檢查", en: "Not checked", ja: "未チェック" },
  "建议更新": { "zh-Hant": "建議更新", en: "Update recommended", ja: "アップデートを推奨" },
  "当前可用，建议更新": { "zh-Hant": "目前可用，建議更新", en: "Ready · Update available", ja: "準備完了 · アップデートが利用可能" },
  "已就绪": { "zh-Hant": "已就緒", en: "Ready", ja: "準備完了" },
  "需配置": { "zh-Hant": "需設定", en: "Setup required", ja: "セットアップが必要です" },
  "需要配置": { "zh-Hant": "需要設定", en: "Setup required", ja: "セットアップが必要です" },
  "组件将保存到当前用户的应用支持目录，不需要管理员权限。": { "zh-Hant": "元件將儲存至目前使用者的應用程式支援資料夾，不需要管理員權限。", en: "Components are stored in the current user’s Application Support folder and do not require administrator access.", ja: "コンポーネントは現在のユーザーの Application Support フォルダーに保存され、管理者アクセスは必要ありません。" },
  "当前设备不满足运行要求：": { "zh-Hant": "此裝置不符合執行要求：", en: "This device does not meet the runtime requirements: ", ja: "このデバイスはランタイム要件を満たしていません: " },
  "请按检查结果处理后重试。": { "zh-Hant": "請依檢查結果處理後重試。", en: "Follow the check results and try again.", ja: "チェック結果に従って再試行してください。" },
  "最新": { "zh-Hant": "最新", en: "Latest", ja: "最新" },
  "请保持应用开启，安装完成后会自动复查": { "zh-Hant": "請保持應用程式開啟，安裝完成後會自動重新檢查", en: "Keep the app open. Requirements will be checked again after installation.", ja: "アプリを開いたままにしてください。インストール後に要件が再度確認されます。" },
  "正在读取本设备环境信息": { "zh-Hant": "正在讀取此裝置的環境資訊", en: "Reading this device’s environment", ja: "このデバイスの環境を読み取る" },
  "✅当前设备环境齐全，无需配置": { "zh-Hant": "✅此裝置的環境已齊備，無需設定", en: "✅This device is ready. No setup is needed.", ja: "✅このデバイスは準備ができています。セットアップは必要ありません。" },
  "✅当前设备环境齐全，可直接使用": { "zh-Hant": "✅此裝置的環境已齊備，可直接使用", en: "✅This device is ready to use.", ja: "✅このデバイスはすぐに使用できます。" },
  "检查本设备，以准备按需配置": { "zh-Hant": "檢查此裝置，以準備按需設定", en: "Check This Device", ja: "このデバイスをチェックしてください" },
  "一键安装/更新": { "zh-Hant": "一鍵安裝/更新", en: "Install/Update", ja: "インストール/アップデート" },
  "更新组件（可选）": { "zh-Hant": "更新元件（選用）", en: "Update Component (Optional)", ja: "コンポーネントの更新 (オプション)" },
  "完成": { "zh-Hant": "完成", en: "Done", ja: "完了" },
  "重新检查": { "zh-Hant": "重新檢查", en: "Check Again", ja: "もう一度確認してください" },
  "重新尝试安装": { "zh-Hant": "重新嘗試安裝", en: "Retry Installation", ja: "インストールを再試行する" },
  "导出诊断报告": { "zh-Hant": "匯出診斷報告", en: "Export Diagnostics", ja: "診断のエクスポート" },
  "自动配置需要联网；下载支持断点续传与最多 3 次重试，安装文件通过 HTTPS 获取并进行 SHA-256 完整性校验。FFmpeg 会按当前 Mac 架构使用主、备发行源。": { "zh-Hant": "自動設定需要網路連線；下載支援斷點續傳與最多 3 次重試。安裝檔案透過 HTTPS 取得，並進行 SHA-256 完整性驗證。FFmpeg 會根據目前 Mac 架構使用主要與備用發佈來源。", en: "Automatic setup requires internet access. Downloads support resuming and up to three retries. Installation files are obtained over HTTPS and verified with SHA-256. FFmpeg uses primary and fallback distribution sources for the current Mac architecture.", ja: "自動セットアップにはインターネットアクセスが必要です。ダウンロードでは、再開と最大 3 回の再試行がサポートされています。インストール ファイルは HTTPS 経由で取得され、SHA-256 で検証されます。 FFmpeg は、現在の Mac アーキテクチャのプライマリおよびフォールバックの配布ソースを使用します。" },
  "应用随附基础组件，无需联网即可满足首次使用；仅可选更新需要联网。下载支持断点续传与重试，并执行 SHA-256 完整性校验。": { "zh-Hant": "應用程式隨附基礎元件，首次使用無需連線；只有選用更新需要網路。下載支援續傳與重試，並執行 SHA-256 完整性驗證。", en: "Baseline components are included for offline first use. Only optional updates require internet access. Downloads support resuming and retries and are verified with SHA-256.", ja: "ベースライン コンポーネントは、オフラインで最初に使用するために含まれています。インターネット アクセスが必要なのは、オプションのアップデートのみです。ダウンロードは再開と再試行をサポートしており、SHA-256 で検証されています。" },
  "第三方组件来源与许可": { "zh-Hant": "第三方元件來源與授權", en: "Third-Party Components and Licenses", ja: "サードパーティのコンポーネントとライセンス" },
  "用于解析公开视频页面，来自": { "zh-Hant": "用於解析公開影片頁面，來自", en: " parses public video pages and is sourced from ", ja: " 公開ビデオ ページを解析し、ソース元は次のとおりです。 " },
  "官方 GitHub": { "zh-Hant": "官方 GitHub", en: " official GitHub repository", ja: " 公式GitHubリポジトリ" },
  "遵循 Unlicense 许可。": { "zh-Hant": "遵循 Unlicense 授權。", en: " under the Unlicense.", ja: " アンライセンスのもとで。" },
  "用于媒体检查、合并与转换，主源为": { "zh-Hant": "用於媒體檢查、合併與轉換，主要來源為", en: " inspects, merges, and converts media. Its primary source is ", ja: " メディアを検査、結合、変換します。その主な情報源は、 " },
  "备用源为": { "zh-Hant": "備用來源為", en: "; fallback sources are ", ja: ";フォールバックソースは " },
  "与": { "zh-Hant": "與", en: " and ", ja: " そして " },
  "实际适用 LGPL/GPL 条款以所安装构建为准。": { "zh-Hant": "實際適用的 LGPL/GPL 條款以已安裝的建置版本為準。", en: ". Applicable LGPL/GPL terms depend on the installed build.", ja: "。適用される LGPL/GPL 条件は、インストールされているビルドによって異なります。" },
  "macOS 13 或更高版本": { "zh-Hant": "macOS 13 或更新版本", en: "macOS 13 or Later", ja: "macOS 13以降" },
  "提供应用界面、网络访问与本地文件处理能力": { "zh-Hant": "提供應用程式介面、網路存取與本機檔案處理能力", en: "Provides the app interface, network access, and local file handling", ja: "アプリインターフェイス、ネットワークアクセス、ローカルファイル処理を提供します。" },
  "验证系统默认下载目录可写，确保文件能正常保存": { "zh-Hant": "驗證系統預設下載位置可寫入，確保檔案能正常儲存", en: "Verifies that the default download location is writable", ja: "デフォルトのダウンロード場所が書き込み可能であることを確認します" },
  "验证所有已支持平台的 DNS 与 HTTPS 连通性": { "zh-Hant": "驗證所有已支援平台的 DNS 與 HTTPS 連線", en: "Checks DNS and HTTPS connectivity for every supported platform", ja: "サポートされているすべてのプラットフォームの DNS および HTTPS 接続をチェックします" },
  "解析视频页面信息并获取可下载的视频、音频资源": { "zh-Hant": "解析影片頁面資訊，並取得可下載的影片與音訊資源", en: "Parses video pages and obtains downloadable video and audio resources", ja: "ビデオ ページを解析し、ダウンロード可能なビデオおよびオーディオ リソースを取得します。" },
  "合并音视频、提取音频并完成下载后的媒体处理": { "zh-Hant": "合併音影、擷取音訊，並完成下載後的媒體處理", en: "Merges audio and video, extracts audio, and performs post-download processing", ja: "オーディオとビデオを結合し、オーディオを抽出し、ダウンロード後の処理を実行します。" },
  "平台网络": { "zh-Hant": "平台網路", en: "Platform Connectivity", ja: "プラットフォームの接続性" },
  "待检查系统版本": { "zh-Hant": "待檢查系統版本", en: "System version not checked", ja: "システムバージョンがチェックされていない" },
  "待检查目录权限": { "zh-Hant": "待檢查資料夾權限", en: "Folder permissions not checked", ja: "フォルダーのアクセス許可がチェックされていません" },
  "待检查平台连通性": { "zh-Hant": "待檢查平台連線", en: "Platform connectivity not checked", ja: "プラットフォームの接続がチェックされていません" },
  "待检查运行组件": { "zh-Hant": "待檢查執行元件", en: "Runtime component not checked", ja: "ランタイムコンポーネントがチェックされていない" },
  "哔哩哔哩": { "zh-Hant": "嗶哩嗶哩", en: "Bilibili", ja: "Bilibili" },
  "抖音": { "zh-Hant": "抖音", en: "Douyin", ja: "Douyin" },
  "快手": { "zh-Hant": "快手", en: "Kuaishou", ja: "Kuaishou" },
  "小红书": { "zh-Hant": "小紅書", en: "Xiaohongshu", ja: "Xiaohongshu" },
  "今日头条": { "zh-Hant": "今日頭條", en: "Toutiao", ja: "Toutiao" },
  "微信视频号": { "zh-Hant": "微信影片號", en: "WeChat Channels", ja: "WeChat Channels" },
};

const dynamicPhrases: Record<string, Translation> = {
  "已完成：": { "zh-Hant": "已完成：", en: "Completed: ", ja: "完了: " },
  "封面已保存：": { "zh-Hant": "封面已儲存：", en: "Cover saved to: ", ja: "表紙の保存場所: " },
  "诊断报告已保存：": { "zh-Hant": "診斷報告已儲存：", en: "Diagnostics saved to: ", ja: "診断は次の場所に保存されます。 " },
  "解析失败：": { "zh-Hant": "解析失敗：", en: "Unable to parse: ", ja: "解析できません: " },
  "下载失败：": { "zh-Hant": "下載失敗：", en: "Download failed: ", ja: "ダウンロードに失敗しました: " },
  "封面下载失败：": { "zh-Hant": "封面下載失敗：", en: "Cover download failed: ", ja: "カバーのダウンロードに失敗しました: " },
  "网络异常：": { "zh-Hant": "網路異常：", en: "Network error: ", ja: "ネットワークエラー: " },
  "权限不足：": { "zh-Hant": "權限不足：", en: "Permission denied: ", ja: "許可が拒否されました: " },
  "配置失败：": { "zh-Hant": "設定失敗：", en: "Setup failed: ", ja: "セットアップに失敗しました: " },
  "正在下载": { "zh-Hant": "正在下載", en: "Downloading ", ja: "ダウンロード中 " },
  "正在校验": { "zh-Hant": "正在驗證", en: "Verifying ", ja: "検証中 " },
  "正在解压": { "zh-Hant": "正在解壓縮", en: "Extracting ", ja: "抽出中 " },
  "正在验证": { "zh-Hant": "正在驗證", en: "Validating ", ja: "検証中 " },
  "正在准备": { "zh-Hant": "正在準備", en: "Preparing ", ja: "準備中 " },
  "正在收尾": { "zh-Hant": "正在完成最後步驟", en: "Finishing", ja: "仕上げ" },
  "下载并合并中": { "zh-Hant": "正在下載並合併", en: "Downloading and merging", ja: "ダウンロードとマージ" },
  "下载中": { "zh-Hant": "下載中", en: "Downloading", ja: "ダウンロード中" },
  "准备下载": { "zh-Hant": "準備下載", en: "Preparing download", ja: "ダウンロードの準備中" },
  "正在检查系统、目录、网络与运行组件": { "zh-Hant": "正在檢查系統、資料夾、網路與執行元件", en: "Checking the system, folders, network, and runtime components", ja: "システム、フォルダー、ネットワーク、およびランタイムコンポーネントのチェック" },
  "设备检查完成": { "zh-Hant": "裝置檢查完成", en: "Device check complete", ja: "デバイスチェックが完了しました" },
  "设备环境检查失败": { "zh-Hant": "裝置環境檢查失敗", en: "Unable to check the device environment", ja: "端末環境が確認できない" },
  "正在准备按需配置": { "zh-Hant": "正在準備按需設定", en: "Preparing setup", ja: "セットアップの準備中" },
  "环境配置完成": { "zh-Hant": "環境設定完成", en: "Environment setup complete", ja: "環境設定完了" },
  "自动配置失败": { "zh-Hant": "自動設定失敗", en: "Automatic setup failed", ja: "自動セットアップに失敗しました" },
  "已取消导出": { "zh-Hant": "已取消匯出", en: "Export cancelled", ja: "エクスポートがキャンセルされました" },
  "诊断报告导出失败": { "zh-Hant": "診斷報告匯出失敗", en: "Unable to export diagnostics", ja: "診断をエクスポートできません" },
  "目录选择失败": { "zh-Hant": "選擇資料夾失敗", en: "Unable to choose a folder", ja: "フォルダを選択できません" },
  "无法打开偏好设置": { "zh-Hant": "無法開啟偏好設定", en: "Unable to open Preferences", ja: "環境設定を開けません" },
  "微信视频号授权清理失败": { "zh-Hant": "清除微信影片號授權失敗", en: "Unable to clear WeChat Channels authorization", ja: "WeChat チャネルの認証をクリアできません" },
  "已清理，下次下载需重新授权": { "zh-Hant": "已清除，下次下載時需重新授權", en: "Cleared. Authorization will be required for the next download.", ja: "クリアしました。次回のダウンロードには認証が必要になります。" },
  "暂停失败": { "zh-Hant": "暫停失敗", en: "Unable to pause", ja: "一時停止できません" },
  "继续下载失败": { "zh-Hant": "繼續下載失敗", en: "Unable to resume download", ja: "ダウンロードを再開できません" },
  "删除失败": { "zh-Hant": "刪除失敗", en: "Unable to delete", ja: "削除できません" },
  "正在暂停": { "zh-Hant": "正在暫停", en: "Pausing", ja: "一時停止" },
  "正在继续": { "zh-Hant": "正在繼續", en: "Resuming", ja: "再開中" },
  "继续下载": { "zh-Hant": "繼續下載", en: "Resuming download", ja: "ダウンロードを再開します" },
  "正在终止并删除": { "zh-Hant": "正在終止並刪除", en: "Stopping and deleting", ja: "停止と削除" },
  "等待下载": { "zh-Hant": "等待下載", en: "Waiting to download", ja: "ダウンロードを待っています" },
  "已暂停，等待开始": { "zh-Hant": "已暫停，等待開始", en: "Paused and waiting", ja: "一時停止して待っています" },
  "上次退出时中断，可重新开始": { "zh-Hant": "上次退出時中斷，可重新開始", en: "Interrupted when the app last quit; ready to restart", ja: "アプリが最後に終了したときに中断されました。再開する準備ができています" },
  "下载已取消": { "zh-Hant": "下載已取消", en: "Download cancelled", ja: "ダウンロードがキャンセルされました" },
  "请检查网络后重试": { "zh-Hant": "請檢查網路後重試", en: "Check your connection and try again", ja: "接続を確認して再試行してください" },
  "请稍后重试": { "zh-Hant": "請稍後重試", en: "Try again later", ja: "後でもう一度試してください" },
  "链接格式不正确": { "zh-Hant": "連結格式不正確", en: "The link format is invalid", ja: "リンク形式が無効です" },
  "暂不支持的平台": { "zh-Hant": "目前不支援的平台", en: "This platform is not supported", ja: "このプラットフォームはサポートされていません" },
  "请输入链接": { "zh-Hant": "請輸入連結", en: "Enter a link", ja: "リンクを入力してください" },
  "未识别到链接": { "zh-Hant": "未識別到連結", en: "No link was found", ja: "リンクが見つかりませんでした" },
  "请先选择合集视频": { "zh-Hant": "請先選擇合集影片", en: "Select at least one collection video", ja: "少なくとも 1 つのコレクションビデオを選択してください" },
  "操作失败": { "zh-Hant": "操作失敗", en: "The operation failed", ja: "操作は失敗しました" },
  "未知作者": { "zh-Hant": "未知作者", en: "Unknown author", ja: "作者不明" },
  "未知日期": { "zh-Hant": "未知日期", en: "Unknown date", ja: "日付不明" },
  "未知时长": { "zh-Hant": "未知時長", en: "Unknown duration", ja: "期間不明" },
  "未命名视频": { "zh-Hant": "未命名影片", en: "Untitled video", ja: "無題のビデオ" },
};

function normalizeLanguage(value: string | undefined): AppLanguage {
  return value === "zh-Hant" || value === "en" || value === "ja" ? value : "zh-Hans";
}

export function translate(key: string, language: AppLanguage): string {
  if (language === "zh-Hans") return key;
  return translations[key]?.[language] ?? key;
}

export function translateDynamicText(text: string, language: AppLanguage): string {
  if (!text || language === "zh-Hans") return text;
  const collectionProgress = text.match(/^第\s*(\d+)\/(\d+)\s*集：(.*)$/s);
  if (collectionProgress) {
    const [, current, total, message] = collectionProgress;
    const localizedMessage = translateDynamicText(message, language);
    return language === "en"
      ? `Episode ${current}/${total}: ${localizedMessage}`
      : language === "ja"
        ? `第 ${current}/${total} 話：${localizedMessage}`
        : `第 ${current}/${total} 集：${localizedMessage}`;
  }
  const preservedValuePrefixes: Record<string, Translation> = {
    "已完成：": { "zh-Hant": "已完成：", en: "Completed: ", ja: "完了：" },
    "封面已保存：": { "zh-Hant": "封面已儲存：", en: "Cover saved to: ", ja: "カバー画像の保存先：" },
    "诊断报告已保存：": { "zh-Hant": "診斷報告已儲存：", en: "Diagnostics saved to: ", ja: "診断レポートの保存先：" },
  };
  const preservedPrefix = Object.keys(preservedValuePrefixes).find((prefix) => text.startsWith(prefix));
  if (preservedPrefix) {
    return preservedValuePrefixes[preservedPrefix][language] + text.slice(preservedPrefix.length);
  }
  const exact = translations[text]?.[language] ?? dynamicPhrases[text]?.[language];
  if (exact) return exact;

  let translated = text;
  const phrases = { ...translations, ...dynamicPhrases };
  Object.entries(phrases)
    .sort(([left], [right]) => right.length - left.length)
    .forEach(([source, values]) => {
      if (translated.includes(source)) translated = translated.split(source).join(values[language]);
    });
  return /\p{Script=Han}/u.test(translated) ? localizedDynamicFallback(text, language) : translated;
}

function localizedDynamicFallback(source: string, language: Exclude<AppLanguage, "zh-Hans">): string {
  const isTraditional = language === "zh-Hant";
  const localized = (traditional: string, english: string, japanese: string) =>
    isTraditional ? traditional : language === "ja" ? japanese : english;
  if (source.includes("下载校验失败")) {
    return localized("下載驗證失敗：產生的媒體檔案不完整或無效。", "Download verification failed: the generated media file is incomplete or invalid.", "ダウンロードの検証に失敗しました。生成されたメディアファイルが不完全または無効です。");
  }
  if (source.includes("封面下载失败")) {
    return localized("封面下載失敗：來源未回傳有效圖片。", "Cover download failed: the source did not return a valid image.", "カバー画像をダウンロードできませんでした。配信元から有効な画像が返されませんでした。");
  }
  if (source.includes("解析失败") || source.includes("解析或下载失败")) {
    return localized("無法解析此連結。內容可能已失效、不是公開內容，或平台限制了存取。", "Unable to parse this link. The content may be unavailable, non-public, or restricted by the platform.", "このリンクを解析できません。コンテンツが無効、非公開、またはプラットフォームによってアクセスが制限されている可能性があります。");
  }
  if (source.includes("下载失败") || source.includes("无法下载")) {
    return localized("下載失敗。媒體來源可能已失效、拒絕存取，或需要重新解析。", "Download failed. The media source may have expired, denied access, or require parsing again.", "ダウンロードに失敗しました。メディアの配信元が無効、アクセス拒否、または再解析が必要な可能性があります。");
  }
  if (source.includes("网络异常") || source.includes("连接") || source.includes("超时")) {
    return localized("網路連線失敗或逾時。請檢查網路後重試。", "The network request failed or timed out. Check your connection and try again.", "ネットワーク要求に失敗したかタイムアウトしました。接続を確認して再試行してください。");
  }
  if (source.includes("未通过") || source.includes("不可用") || source.includes("过低")) {
    return localized("未通過檢查，請依詳細結果處理後重試。", "The check did not pass. Review the details, resolve the issue, and try again.", "確認に合格しませんでした。詳細を確認して問題を解決し、再試行してください。");
  }
  if (source.includes("通过") || source.includes("正常") || source.includes("就绪") || source.includes("可用")) {
    return localized("檢查通過，目前可正常使用。", "Check passed and ready to use.", "確認に合格しました。現在利用できます。");
  }
  if (source.includes("权限") || source.includes("写入") || source.includes("目录")) {
    return localized("無法存取所選位置。請檢查資料夾與磁碟權限。", "The selected location cannot be accessed. Check folder and disk permissions.", "選択した場所にアクセスできません。フォルダとディスクの権限を確認してください。");
  }
  if (source.includes("微信视频号") || source.includes("腾讯元宝")) {
    return localized("微信影片號授權或媒體請求失敗。請重新登入後再試。", "The WeChat Channels authorization or media request failed. Sign in again and retry.", "WeChat Channels の認証またはメディア要求に失敗しました。再度サインインしてお試しください。");
  }
  if (source.includes("安装") || source.includes("配置") || source.includes("组件") || source.includes("FFmpeg") || source.includes("yt-dlp")) {
    return localized("無法完成元件設定或驗證。請檢查網路、磁碟空間與檔案權限後重試。", "Component setup or verification could not be completed. Check the network, available disk space, and file permissions, then retry.", "コンポーネントの設定または検証を完了できません。ネットワーク、空き容量、ファイル権限を確認して再試行してください。");
  }
  if (source.includes("正在") || source.includes("获取") || source.includes("检查") || source.includes("下载中")) {
    return localized("正在處理，請稍候…", "Processing…", "処理中です…");
  }
  if (source.includes("已完成") || source.includes("已配置")) {
    return localized("操作已完成。", "The operation is complete.", "操作が完了しました。");
  }
  return localized("無法完成操作，請重試。", "The operation could not be completed. Try again.", "操作を完了できません。再試行してください。");
}

type I18nValue = {
  language: AppLanguage;
  t: (key: string) => string;
  td: (text: string) => string;
};

const I18nContext = createContext<I18nValue>({
  language: "zh-Hans",
  t: (key) => key,
  td: (text) => text,
});

export function I18nProvider({ children }: { children: ReactNode }) {
  const [language, setLanguage] = useState<AppLanguage>(() => normalizeLanguage(window.__ekStreamDLLanguage));

  useEffect(() => {
    const handleLanguageChange = (event: Event) => {
      const nextLanguage = (event as CustomEvent<string>).detail;
      setLanguage(normalizeLanguage(nextLanguage));
    };
    window.addEventListener("ek-streamdl-language-change", handleLanguageChange);
    return () => window.removeEventListener("ek-streamdl-language-change", handleLanguageChange);
  }, []);

  useEffect(() => {
    document.documentElement.lang = language;
  }, [language]);

  const value = useMemo<I18nValue>(
    () => ({
      language,
      t: (key) => translate(key, language),
      td: (text) => translateDynamicText(text, language),
    }),
    [language],
  );

  return <I18nContext.Provider value={value}>{children}</I18nContext.Provider>;
}

export function useI18n() {
  return useContext(I18nContext);
}
