# Mac Interval Recorder

一个原生 macOS 摄像头间隔录制应用：点击“开始”后立即录制一个片段，随后按设定间隔重复录制；点击“结束并导出”后，将所有片段按顺序合并成一个视频。

## 使用方法

1. 使用 Xcode 15 或更高版本打开 `MacIntervalRecorder.xcodeproj`。
2. 在项目的 **Signing & Capabilities** 中选择你自己的 Team（仅本机运行时也可让 Xcode 自动管理签名）。
3. 选择 **My Mac**，点击 Run。
4. 首次运行时允许摄像头和麦克风权限。
5. 选择摄像头、间隔和片段时长，然后点击“开始”。
6. 点击“结束并导出”，选择 `.mov` 文件的保存位置。

默认设置为每 5 分钟录制 5 秒，并包含麦克风声音。录制期间应用会阻止 Mac 自动进入空闲睡眠。关闭应用、合上屏幕或手动睡眠仍会中断录制。

## 不安装 Xcode：使用 GitHub Actions 构建

1. 将整个项目上传到 GitHub 仓库的根目录。
2. 打开仓库的 **Actions** 页面，选择 **Build macOS App**。
3. 点击 **Run workflow**；推送到 `main` 分支时也会自动构建。
4. 构建完成后，在运行详情页底部下载 `MacIntervalRecorder-macOS`。
5. 解压下载的 artifact，再解压其中的 `MacIntervalRecorder.app.zip`。
6. 首次运行时右键应用并选择“打开”。这是仅供个人使用的临时签名版本，不需要付费开发者账号。

## 隐私

视频片段仅保存在本机临时目录中。成功导出或点击“清除片段”后，临时片段会被删除。
