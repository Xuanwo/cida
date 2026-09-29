# 官网

cida.xuanwo.io，面向不看 GitHub 的 Mac 用户。页面就是仓库里的 [`website/`](../../website)：`index.html`、`en/index.html`、`releases/index.html`，直接引用 `Design/boards` 的令牌与组件，所以实现与应用的设计保持一致；官网没有单独的 board。README 继续服务开发者；构建、命令行和设计稿只在官网链接到 GitHub。

## 一、内容

一页回答三件事，按这个顺序：辞达做什么、怎么装、文字去哪里。

1. **首屏**：标题「辞达而已矣」，出自《论语·卫灵公》，后跟标志里的 accent 光标；说明两行：第一行解释标题（言辞能把意思表达清楚，就够了），第二行说辞达做什么，不写具体按键，怎么用交给下面的面板演示；「下载辞达」按钮（`https://cida-releases.xuanwo.io/latest/Cida.dmg`），下面一行写版本号、系统要求与计费方式。再往下是应用的面板，正在流出一段译文。
2. **五种用法**：翻译选中的文字、润色、翻译屏幕上的文字、在原处读一段、翻译整个窗口。每行左边是动作名、默认快捷键和一句话，右边是对应的演示视频（`website/assets/clips`，与 README 的 GIF 出自同一段录屏，见 `scripts/make-demo-media.py`）。这五项不是先后步骤，不编号。全局快捷键可以重新录制，所以标题和正文只写动作，按键只作为默认值出现在动作名下面，节标题下写一次「快捷键都是默认值，可以在设置里重新录制」。
3. **三步装好**：打开 DMG、让 AI 助手配置模型、把 API Key 存进钥匙串，是真实的先后顺序，编号。下面是两个可选权限，开启后与不开启时各一列。
4. **隐私**：三句话，与 README 的隐私一节同义。
5. **最近更新**：最新一版的 `docs/releases/<version>.md`，画成应用里的更新面板；旁边链接到全部更新记录 `/releases/`。
6. **页脚**：左边是图标，右侧三行：「辞达」、名字的出处、作者署名（链接到 https://x.com/xuanwo；中文页「由 @xuanwo 用心制作」，英文页「Proudly brought to you by @xuanwo」）；最右是 GitHub、许可证、English，与第一行对齐。页脚只用一种声音，也只用页面自己的语言：14px 界面字、22px 行距，「辞达」与 @xuanwo 两个名字用墨色，其余是 `text-secondary`，链接悬停时变墨色并加下划线。标题的含义已在首屏解释，页脚不再重复。

英文版在 `/en/`，结构相同，文字取自 `README.en.md`。

分享卡片（`og:description`）只写标题「辞达而已矣」，英文页加一句英文解释；搜索摘要（`description`）是标题加两行说明。

不放：博客、文档站、FAQ、定价、统计或任何埋点（与「不收集任何数据」冲突）、深色模式（应用只有浅色）、订阅表单。

## 二、样式

- 颜色、字体、圆角与面板全部取自 `tokens.css` 与 `components.css`，官网自己的样式只管版面和首屏动画（`website/site.css`）。
- 整页的重点在首屏：大号衬线标题后跟一枚静止的 accent 光标（与标志同一元素），下面是正在流出译文的面板。其他地方不加粗色、不加斜体。
- 按键画成键帽（白底、细边、底边加粗），只用在动作名下面和正文里，字号不超过动作名。
- 标题用 `font-brand`（Noto Serif SC 600），正文用 `font-ui`。隐私一节放在 `surface-paper` 上、用结果栏的衬线字，因为那是辞达自己说的话。
- `accent` 只用于首屏标题后的光标、下载按钮、安装步骤的序号、「全部更新记录」链接和面板里本来就有的三处。
- 首屏居中，与面板在屏幕中央唤出一致；以下各节左对齐，内容宽 1152。窄于 720 时单栏，面板随屏幕宽度重排，不缩放成图片。

## 三、首屏面板

- 原文用讲文字本身的公版英文段落，与「辞达而已矣」同义：William Strunk Jr.《The Elements of Style》（1918）的「Vigorous writing is concise…」，以及梭罗《瓦尔登湖》（1854）的「I went to the woods because I wished to live deliberately…」。译文由我们自己写定，不现场请求模型。
- 面板循环演示翻译（`website/site.js`），换段照应用处理一次新选区的顺序（`spec/panel.md` §一、`spec/streaming-motion.md` §二）：写完后停留 3.5 秒；新原文 180ms 淡入替换，旧译文变为已过时（`text-secondary`）停 0.9 秒；随后提交，停止与复制按钮 150ms（`motion-icon-swap-ms`）交叉淡化，旧译文 150ms 淡去，结果栏以 `motion-height-ms` 收到一行等待光标；新译文按应用的流式节奏逐字流出，原文栏与结果栏的高度都以 `motion-height-ms` 过渡，不跳变。这是页面唯一不由访客触发的动画。舞台先留出最长一段写完时的高度，下面的内容不跟着移动。英文页原文与译文对调。
- 渐隐是辞达最有辨识度的动效，首屏要让人看清：每个字在光标后按 `motion-char-in-ms` 从 opacity 0、blur `motion-blur-char-px` 淡入，曲线与应用的 `StreamGlyphFadeAnimation` 相同，是三次 ease-out，所以书写头后面总有几个字处在不同的淡入阶段。设计稿画的是其中一帧：最后七个字从几乎透明、带模糊，到接近全墨。
- 页面里写好的是第一段写到一半的一帧，首次绘制就是它；动画从这一帧接着写，正在淡入的字补完淡入，不清空重来。没有 JavaScript 时停在这一帧；开启「减弱动态效果」时只显示完成的译文。
- 首次绘制就是最终样子：三种字体在 `<head>` 预加载并以 `font-display: block` 显示，不先用系统字体再替换；面板的控制条由 `components.js` 在 `<head>` 同步生成，不在加载后才出现。
- 五个演示片段只在滚到屏幕上时播放，离开就暂停；减弱动态效果时不自动播放，给出播放控件。

## 四、发布

- 静态文件，不用框架。`scripts/build-website.py` 复制 `website/`，把指向仓库其他位置的路径换成 `/assets` 下的文件，并按 release tag（不含 rc）写入最新版本号、上一个版本号和更新说明，生成更新记录。版本号取自 tag 而不是 `docs/releases`：说明在打 tag 前就合入，页面只显示已经能下载的版本。
- 字体子集与演示视频提前做好并提交，构建不再处理：字体只含站点用到的字，页面出现未覆盖的字时构建失败，提示重新子集；视频有 760 与 1520 两种宽度，按屏幕倍率选择，外加首帧海报。
- 部署在 Cloudflare Workers 的静态资源（`website/wrangler.jsonc`，Worker `cida-website`）。自定义域名 cida.xuanwo.io 在 Cloudflare 上绑定一次，不写进配置，部署不碰它，所以部署令牌只需要这一个 Worker 的 Editor 权限。`.github/workflows/website.yml` 在 main 上相关文件变化后部署；发版不自动部署，发版后手动运行一次这个工作流。
