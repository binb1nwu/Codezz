import 'package:flutter/widgets.dart';

/// zh-CN / en-US strings. Labels that exist in ZCode reuse ZCode's wording
/// (`packages/ui/src/i18n/locales`).
class S {
  const S._(this.zh);
  final bool zh;

  static S of(BuildContext context) =>
      S._(Localizations.maybeLocaleOf(context)?.languageCode == 'zh');

  /// For text built outside the widget tree (notifications).
  const S.lang({required bool zh}) : this._(zh);

  String _(String zhText, String enText) => zh ? zhText : enText;

  // App / devices
  String get appName => 'Codezz';
  String get devices => _('设备', 'Devices');
  String get addDevice => _('添加设备', 'Add device');
  String get editDevice => _('编辑设备', 'Edit device');
  String get deviceLink => _('远程控制链接', 'Remote control link');
  String get deviceLinkHint => 'https://zcode.z.ai/remote/v4?sid=…';
  String get deviceLinkHelp => _(
      '在电脑上的 ZCode 中打开远程控制，复制手机连接链接（https://zcode.z.ai/remote/…）粘贴到这里，或扫描它的二维码。也支持 zcode --web 输出的局域网链接。',
      'In ZCode on your computer, open remote control and paste the mobile link (https://zcode.z.ai/remote/…) here, or scan its QR code. Links printed by zcode --web work too.');
  String get deviceName => _('名称（可选）', 'Name (optional)');
  String get scanQr => _('扫码', 'Scan QR');
  String get paste => _('粘贴', 'Paste');
  String get save => _('保存', 'Save');
  String get cancel => _('取消', 'Cancel');
  String get delete => _('删除', 'Delete');
  String get rename => _('重命名', 'Rename');
  String get retry => _('重试', 'Retry');
  String get reconnect => _('重新连接', 'Reconnect');
  String get updateLink => _('更新链接', 'Update link');
  String get removeDevice => _('移除设备', 'Remove device');
  String removeDeviceConfirm(String name) =>
      _('确定移除「$name」？', 'Remove "$name" from this app?');
  String get linkInvalid => _('无法识别的链接', 'Unrecognized link');
  String get linkIncomplete => _('远程链接不完整（需要 sid、hash 和 t），请重新复制。',
      'The remote link is incomplete (sid, hash and t are required). Copy it again.');
  String get noDevices => _('还没有设备', 'No devices yet');
  String get noDevicesHint => _('添加一台运行 ZCode 的电脑，即可在手机上继续任务。',
      'Link a computer running ZCode to continue your tasks from here.');
  String get online => _('已连接', 'Connected');
  String get connecting => _('连接中', 'Connecting');
  String get offline => _('已断开', 'Disconnected');
  String get unauthorized => _('链接已失效', 'Link rejected');
  String get unauthorizedHint => _('远程链接已过期或被撤销（zcode --web 每次启动也会换新令牌），请在电脑上复制新链接后更新。',
      'The remote link expired or was revoked (zcode --web also changes its token on every start). Copy a fresh link on your computer and update it.');
  String retryingIn(int s) => _('$s 秒后重试', 'retrying in ${s}s');
  String get workspace => _('工作区', 'Workspace');
  String get workspaceDisconnected => _('未连接', 'Disconnected');
  String workspaceReconnecting(String name) =>
      _('正在重新连接「$name」…', 'Reconnecting "$name"…');
  String workspaceReconnectFailed(String name, String error) =>
      _('无法连接「$name」：$error', 'Could not connect "$name": $error');
  String workspaceFallback(String name, String error) =>
      _('「$name」暂时无法打开，已切换到其他工作区：$error', '"$name" could not be opened, switched to another workspace: $error');
  String get switchDevice => _('切换设备', 'Switch device');

  // Sidebar
  String get newTask => _('新建任务', 'New task');
  String get search => _('搜索', 'Search');
  String get tasks => _('任务', 'Tasks');
  String get pinned => _('置顶', 'Pinned');
  String get archived => _('已归档', 'Archived');
  String get noTasks => _('还没有任务', 'No tasks yet');
  String get pin => _('置顶', 'Pin');
  String get unpin => _('取消置顶', 'Unpin');
  String get archive => _('归档', 'Archive');
  String get unarchive => _('取消归档', 'Unarchive');
  String get deleteTaskConfirm => _('删除后任务将从列表中移除。', 'The task will be removed from the list.');
  String get settings => _('设置', 'Settings');

  // Status
  String get statusRunning => _('执行中', 'Running');
  String get statusWaiting => _('等待确认', 'Awaiting approval');
  String get statusError => _('出错', 'Error');
  String get statusInterrupted => _('已中断', 'Interrupted');
  String get statusCompleted => _('已完成', 'Completed');

  // Conversation
  String greeting(int hour) {
    if (hour < 5) return _('夜深了！剩下的交给我。', 'Late night! Leave the rest to me.');
    if (hour < 12) return _('早上好！剩下的交给我。', 'Good morning! Leave the rest to me.');
    if (hour < 18) return _('下午好！剩下的交给我。', 'Good afternoon! Leave the rest to me.');
    return _('晚上好！剩下的交给我。', 'Good evening! Leave the rest to me.');
  }

  String get placeholderNewTask => _('向 ZCode 提问…', 'Ask ZCode anything…');
  String get placeholderFollowUp => _('提出后续修改要求', 'Ask for follow-up changes');
  String get placeholderQueue => _('继续输入以排队后续修改', 'Keep typing to queue follow-up changes');
  String get send => _('发送', 'Send');
  String get stop => _('停止生成', 'Stop');
  String get thinking => _('正在思考', 'Thinking');
  String get thought => _('思考', 'Thought');
  String workedFor(String d) => _('已工作 $d', 'Worked for $d');
  String get working => _('工作中', 'Working');
  String workingFor(String d) => _('工作中 $d', 'Working for $d');
  String get scrollToBottom => _('滚动到底部', 'Scroll to bottom');
  String get loadOlder => _('加载更早的消息', 'Load earlier messages');
  String get loadingConversation => _('正在加载会话…', 'Loading conversation…');
  String get syncing => _('同步中…', 'Syncing…');
  String get copied => _('已复制', 'Copied');
  String get copy => _('复制', 'Copy');
  String get retryTurn => _('重试', 'Retry');
  String get edit => _('编辑', 'Edit');
  String get queued => _('排队中', 'Queued');
  String get sendNow => _('立即', 'Steer');
  String get queuePaused => _('队列已暂停', 'The queue is paused');
  String get queuePausedStopped =>
      _('由于你中断了当前响应，队列已暂停', 'The queue was paused because you stopped the current response');
  String get queuePausedError =>
      _('由于当前响应出错，队列已暂停（内容未丢失）', 'The queue was paused because the response failed');
  String get removeQueued => _('移除待发送消息', 'Remove queued message');
  String get resume => _('继续', 'Resume');
  String get background => _('后台任务', 'Background');
  String get compact => _('压缩上下文', 'Compact');
  String get changes => _('变更', 'Changes');
  String get heldQueueTitle => _('队列已暂停', 'Queue is paused');
  String get heldQueueBody =>
      _('队列中还有待发送的消息。', 'There are queued messages waiting.');
  String get clearQueueAndSend => _('清空队列后发送', 'Clear queue and send');
  String get keepQueueAndSend => _('保留队列立即发送', 'Keep queue and send');
  String get offlineBanner => _('连接已断开，正在重连…', 'Disconnected, reconnecting…');
  String get noModels => _('当前设备没有可用的模型，请先在电脑上配置。',
      'No model configured on this device. Set one up on the computer first.');
  String get context => _('上下文', 'Context');
  // chat.contextUsage.* in ZCode
  String get contextUsageTitle => _('上下文容量', 'Context windows');
  String contextUsage(String used, String total) =>
      _('上下文已用 $used / 总量 $total', 'Context usage $used of $total');
  String get cacheHitRate => _('平均缓存命中率', 'Average cache hit rate');
  // sidebar.usage.plan.* in ZCode
  String get planTitle => _('剩余额度', 'Usage remaining');
  String get startPlanTitle => _('今日余额', "Today's balance");
  String planQuota(String key) => switch (key) {
        'fiveHour' => _('5 小时', '5 hours'),
        'weekly' => _('每周', 'Weekly'),
        'toolCalls' => _('工具调用', 'Tool calls'),
        'mcp' => 'ZCode MCP',
        'balance' => startPlanTitle,
        _ => key,
      };
  String get planMcpDescription =>
      _('ZCode 预置插件 MCP 每日合计额度', 'Daily aggregate quota for ZCode built-in plugin MCPs');
  String get planLoading => _('同步中...', 'Syncing...');
  String get planRefresh => _('刷新额度', 'Refresh quota');
  String get planUpdateFailed => _('可能网络原因，更新失败', 'Possible network issue');
  String planUnavailable(String? reason) => switch (reason) {
        'not_configured' => _('未找到已连接的编程套餐账号。', 'No connected Coding Plan account found.'),
        'not_authenticated' => _('登录后查看剩余额度。', 'Login to view plan usage.'),
        'no_plan' => _('暂无有效编程套餐', 'No active Coding Plan'),
        _ => _('暂无可展示的权益数据。', 'No available entitlement data yet.'),
      };
  String contextSource(String source) => switch (source) {
        'messages' => _('消息', 'Messages'),
        'system_prompt' => _('系统提示词', 'System prompt'),
        'meta_user_context' => _('其他', 'Meta context'),
        'skills' => _('技能', 'Skills'),
        'tool_prompt' => _('工具提示词', 'Tool prompt'),
        'system_tool_schemas' => _('系统工具', 'System tools'),
        'mcp_tool_schemas' => _('MCP 工具', 'MCP tools'),
        _ => source,
      };

  // Composer "+" (chat.composer.* / chat.mention.* / chat.attachments.*)
  String get addContext => _('添加上下文', 'Add context');
  String get addSection => _('添加', 'Add');
  String get attachment => _('附件', 'Attachments');
  String get goal => _('目标', 'Goal');
  String get plugins => _('插件', 'Plugins');
  String get pluginsEmpty => _('没有可引用的插件', 'No plugins available to reference');
  String get files => _('文件', 'Files');
  String get filesEmpty => _('没有匹配的文件', 'No matching files');
  String get sessions => _('会话', 'Sessions');
  String get sessionsEmpty => _('没有匹配的近期会话', 'No recent sessions match');
  String get mentionLoading => _('搜索中...', 'Searching...');
  String get untitledSession => _('未命名会话', 'Untitled session');
  String pluginDescription(String marketplace, int skills, int mcp) =>
      _('$marketplace · $skills 技能 · $mcp MCP', '$marketplace · $skills skills · $mcp MCP');
  String get truncatedNote => '[内容过长，已截断]';
  String uploading(int progress) => _('正在上传 $progress%', 'Uploading $progress%');
  String get uploadQueued => _('等待上传', 'Waiting to upload');
  String get uploadWaitingSession => _('正在等待会话', 'Waiting for session');
  String get uploadCommitting => _('正在完成上传', 'Finishing upload');
  String get uploadReady => _('上传完成', 'Upload complete');
  String uploadFailed(String message) => _('上传失败：$message', 'Upload failed: $message');
  String get uploadRetry => _('重试上传', 'Retry upload');
  String get removeAttachment => _('移除附件', 'Remove attachment');
  String maxAttachments(int count) => _('最多只能添加 $count 个附件', 'You can attach up to $count attachments');
  String attachmentTooLarge(String name) =>
      _('$name 过大，请压缩到 20 MB 以内后重试。', '$name is too large. Please compress it to 20 MB or smaller and try again.');
  String get attachmentUnreadable => _('附件缺少可读取内容', 'The attachment has no readable content');
  String readFailed(String message) => _('读取附件失败：$message', 'Failed to read attachment: $message');

  // Status capsule (chat.summaryPanel.* / chat.statusPanel.* in ZCode)
  String get statusTitle => _('状态', 'Status');
  String get showStatus => _('展开状态', 'Expand status');
  String get collapseStatus => _('收起为胶囊', 'Collapse to capsule');
  String get gitTools => _('Git 工具', 'Git tools');
  String get changesLabel => _('更改', 'Changes');
  String get branch => _('分支', 'Branch');
  String get progress => _('进程', 'Progress');
  String get terminals => _('终端', 'Terminals');
  String get agents => _('智能体', 'Agents');
  String get stop2 => _('停止', 'Stop');
  String get pauseGoal => _('暂停目标', 'Pause goal');
  String get resumeGoal => _('继续目标', 'Resume goal');
  String goalIteration(int n) => _('第 $n 次迭代', 'Iteration $n');
  String runningBackground(int n) => _('$n 个后台运行', '$n in background');
  String runningBackgroundShort(int n) => _('$n 后台', '$n background');
  String runningAgents(int n) => _('$n 运行', '$n running');
  String todoCompletedFold(int n) => _('已完成 $n 项', '$n completed');
  String todoEarlierFold(int n) => _('前面 $n 项', '$n earlier');
  String todoLaterFold(int n) => _('后面 $n 项', '$n later');
  String todoWaitingFold(int n) => _('待处理 $n 项', '$n waiting');
  String elapsed(int seconds) {
    final h = seconds ~/ 3600, m = seconds % 3600 ~/ 60, sec = seconds % 60;
    return [
      if (h > 0) _('$h小时', '${h}h'),
      if (h > 0 || m > 0) _('$m分', '${m}m'),
      _('$sec秒', '${sec}s'),
    ].join(' ');
  }

  String runningFor(int seconds) => seconds < 60
      ? _('已运行 $seconds 秒', 'Running for ${seconds}s')
      : _('已运行 ${seconds ~/ 60} 分 ${seconds % 60} 秒', 'Running for ${seconds ~/ 60}m ${seconds % 60}s');
  String apiRetry(int attempt, int max) => _('重新连接中... $attempt/$max', 'Reconnecting... $attempt/$max');
  String get openRunningTerminals => _('运行中的终端', 'Open running terminals');
  String get openRunningAgents => _('打开运行中的智能体', 'Open running agents');
  String get openRunningBoth => _('打开运行中的终端与智能体', 'Open running terminals and agents');
  String get showDetails => _('展开详情', 'Show details');
  String get dismissError => _('关闭错误提示', 'Dismiss error');

  // Side pane (sidePane.* / git.* / terminal.* in ZCode)
  String get togglePanel => _('切换面板', 'Toggle panel');
  String get back => _('返回', 'Back');
  String get openTab => _('打开标签页', 'Open tab');
  String get openTabDescription => _('选择要在侧边面板中打开的标签。', 'Choose a tab to open in the side pane.');
  String get addTab => _('新增标签', 'Add tab');
  String closeTab(String title) => _('关闭 $title', 'Close $title');
  String get review => _('审查', 'Review');
  String get terminal => _('终端', 'Terminal');
  String get terminalExited => _('[进程已退出]', '[Process exited]');
  String get terminalFailed => _('[终端启动失败]', '[Terminal failed to start]');
  String get terminalDisconnected => _('[连接已断开]', '[Disconnected]');
  String get terminalCopy => _('复制', 'Copy');
  String get terminalPaste => _('粘贴', 'Paste');
  String gitSource(String id) => switch (id) {
        'unstaged' => _('未暂存', 'Unstaged'),
        'staged' => _('已暂存', 'Staged'),
        'branch' => _('全部分支更改', 'All branch changes'),
        _ => id,
      };
  String get gitRefresh => _('刷新', 'Refresh');
  String get gitLoading => _('加载中...', 'Loading...');
  String get gitLoadingDescription =>
      _('正在读取当前工作区的 Git 状态和文件改动。', 'Reading Git status and changed files for the current workspace.');
  String get gitEmptyTitle => _('当前来源下没有可展示的改动', 'No changes are available in this source');
  String get gitEmptyDescription => _('可以切换其它来源，或等当前 workspace 产生新的 Git 改动后再查看。',
      'Switch to another source, or wait until this workspace has new Git changes to inspect.');
  String get gitNotRepositoryTitle => _('当前 workspace 不在 Git 仓库中', 'This workspace is not inside a Git repository');
  String get gitNotRepositoryDescription => _('打开一个 Git 仓库目录后，这里会展示当前 workspace 作用域内的改动。',
      'Open a Git repository directory and this pane will show changes scoped to the current workspace.');
  String get gitUnavailableTitle => _('当前环境没有可用的 Git', 'Git is not available in this environment');
  String get gitUnavailableDescription => _('请先安装 Git，或确认当前运行环境里可以执行 git 命令。',
      'Install Git first, or make sure the current runtime environment can execute the git command.');
  String get gitErrorTitle => _('无法加载 Git 改动', 'Could not load Git changes');
  String gitErrorDescription(String message) => _('Git 返回错误：$message', 'Git returned an error: $message');
  String get diffBinary => _('无法预览二进制 Diff', 'Binary diff preview is unavailable');
  String get diffTruncated => _('Diff 已裁剪', 'Diff has been truncated');
  String get diffUnavailable => _('暂时无法预览这个 Diff', 'This diff is unavailable right now');

  // Tool status
  String get toolRunning => _('执行中', 'Running');
  String get toolDone => _('已执行', 'Done');
  String get toolFailed => _('执行失败', 'Failed');
  String get toolDenied => _('已拒绝', 'Denied');
  String get toolStopped => _('已停止', 'Stopped');
  String get toolPending => _('等待确认', 'Awaiting approval');
  // codeViewer.* in ZCode
  String get more => _('更多', 'More');
  String get openFile => _('打开文件', 'Open file');
  String get markdownSource => _('显示源码', 'Show source');
  String get wrapLines => _('自动换行', 'Wrap lines');
  String get copyAbsolutePath => _('复制绝对路径', 'Copy absolute path');
  String get copyRelativePath => _('复制相对路径', 'Copy relative path');
  String get loadingFile => _('正在读取文件...', 'Loading file...');
  String get loadingImage => _('正在加载图片预览...', 'Loading image preview...');
  String get loadingMedia => _('正在加载媒体预览...', 'Loading media preview...');
  String get fileMissing =>
      _('文件不存在，或当前环境无法访问该路径。', 'The file does not exist, or this environment cannot access that path.');
  String get fileTooLarge => _('文件超过 256 KB 预览上限，请使用其他编辑器打开以查看完整内容。',
      'This file exceeds the 256 KB preview limit. Open it in another editor to view the full contents.');
  String get binaryFile => _('当前文件看起来像二进制内容，暂不支持代码预览。',
      'This file looks like binary data and cannot be previewed as code yet.');
  String get emptyFile => _('文件为空', 'File is empty');
  String get imageUnavailable => _('暂时无法显示这张图片。', 'This image preview is currently unavailable.');
  String get mediaUnsupported => _('当前环境不支持播放这种媒体格式。', 'This environment cannot play this media format.');
  String get mediaLoadFailed => _('媒体加载失败，请稍后重试或使用外部应用打开。',
      'Media failed to load. Try again later or open it in an external application.');
  String get mediaTooLarge => _('媒体文件超过 300 MB，无法在手机上预览。', 'This media file is over 300 MB and cannot be previewed on the phone.');
  String get pdfUnavailable => _('暂时无法预览这个 PDF。', 'This PDF preview is currently unavailable.');
  String get officeUnavailable => _('暂时无法预览这个 Office 文件。', 'This Office file cannot be previewed.');
  String get loadingPdf => _('正在加载 PDF...', 'Loading PDF...');
  String get loadingPptx => _('正在加载演示文稿...', 'Loading presentation...');
  String get pptxLoadError => _('演示文稿加载失败', 'Failed to load presentation');
  String get documentTooLarge =>
      _('文件超过 64 MB，无法在手机上预览。', 'This file is over 64 MB and cannot be previewed on the phone.');

  // chat.toolCall.* in ZCode
  String get todoKind => _('待办', 'Todo');
  String get noOutput => _('没有输出。', 'No output.');
  String get result => _('结果', 'Result');
  String get callDetails => _('查看调用详情', 'View call details');
  String get parameters => _('调用参数', 'Parameters');
  String get copyResult => _('复制结果', 'Copy result');
  String diffPreviewTruncated(int n) => _('Diff 预览已截断：为保持界面流畅，省略了 $n 行。',
      'Diff preview truncated: $n lines omitted to keep UI responsive.');

  // Modes (mode.label.glm.* in ZCode)
  String modeLabel(String mode) => switch (mode) {
        'build' => _('变更前确认', 'Ask before changes'),
        'edit' => _('自动编辑', 'Edit automatically'),
        'plan' => _('计划模式', 'Plan mode'),
        'yolo' => _('完全访问', 'Full access'),
        _ => mode,
      };
  String modeDescription(String mode) => switch (mode) {
        'build' => _('改文件前先问我。', 'Ask before file changes.'),
        'edit' => _('自动编辑文件。', 'Edit files automatically.'),
        'plan' => _('编辑前先出计划。', 'Plan before editing.'),
        'yolo' => _('减少确认次数。', 'Run with fewer confirmations.'),
        _ => '',
      };
  String get model => _('选择模型', 'Model');
  String get modelShort => _('模型', 'Model');
  String get reasoning => _('思考档位', 'Reasoning');
  String reasoningLevel(String level) => switch (level) {
        'disabled' || 'none' || 'off' => _('关闭', 'Off'),
        'minimal' => _('极简', 'Minimal'),
        'enabled' => _('开', 'On'),
        'low' => _('低', 'Low'),
        'medium' => _('中', 'Medium'),
        'high' => _('高', 'High'),
        'xhigh' => _('超高', 'Extra high'),
        'max' => _('极高', 'Max'),
        _ => level,
      };

  // Interactions
  String get permissionTitle => _('需要权限', 'Permission required');
  String get allow => _('允许', 'Allow');
  String get deny => _('拒绝', 'Deny');
  String get feedbackPlaceholder => _('告诉模型接下来应该怎么做...', 'Tell the model what to do instead...');
  String get customAnswer => _('输入你的回答...', 'Type your answer...');
  String get submit => _('提交', 'Submit');
  String get next => _('下一题', 'Next');
  String get skip => _('跳过', 'Skip');
  String get decline => _('拒绝回答', 'Decline');
  String get questionTitle => _('需要你的回答', 'Input needed');

  // Settings
  String get appearance => _('外观', 'Appearance');
  String get theme => _('主题', 'Theme');
  String get themeSystem => _('跟随系统', 'System');
  String get themeLight => _('浅色', 'Light');
  String get themeDark => _('深色', 'Dark');
  String get themeOled => _('OLED 黑', 'OLED');
  String get textSize => _('字体大小', 'Text size');
  String get contextDisplay => _('上下文用量', 'Context usage');
  String get contextDisplayRing => _('圆环', 'Ring');
  String get contextDisplayBar => _('输入框占用条', 'Input box fill');
  String get quotaPlacement => _('5 小时 / 每周额度', '5-hour / weekly quota');
  String get quotaPlacementRing => _('圆环', 'Ring');
  String get quotaPlacementHeader => _('顶部', 'Header');
  // Notifications
  String get runningTasksChannel => _('运行中的任务', 'Running tasks');
  String get finishedTasksChannel => _('任务完成', 'Finished tasks');
  String tasksRunning(int n) => _('$n 个任务运行中', '$n tasks running');
  String get taskFinished => _('任务已完成', 'Task finished');
  String get taskFailed => _('任务出错', 'Task failed');
  String get taskInterrupted => _('任务已中断', 'Task interrupted');
  String get glassEffect => _('毛玻璃效果', 'Frosted glass');
  String get glassEffectHint => _('顶栏、输入框、状态胶囊和弹出面板半透明模糊；低端机卡顿时可关闭。', 'Translucent, blurred header, composer, status capsule and sheets. Turn off if scrolling stutters.');
  String planQuotaShort(String key) => switch (key) {
        'fiveHour' => '5h',
        'weekly' => _('周', 'wk'),
        'balance' => _('今日', 'today'),
        _ => key,
      };
  String get diagnostics => _('连接日志', 'Connection log');
  String get about => _('关于', 'About');
  String get aboutBody => _('Codezz 是 ZCode 的多设备移动客户端，通过 ZCode 远程控制中继（或 zcode --web）连接每台电脑，说 ZCode 自己的 Channel RPC 与 Conversation V4 协议。',
      "Codezz is a multi-device mobile client for ZCode. It reaches each computer through ZCode's remote-control relay (or zcode --web) and speaks ZCode's own Channel RPC and Conversation V4 protocols.");
  String get clear => _('清空', 'Clear');
  String get error => _('出错了', 'Something went wrong');
}
