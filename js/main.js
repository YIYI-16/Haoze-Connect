// 渲染配置信息
document.title = CONFIG.appName;
document.getElementById('app-title').textContent = CONFIG.appName;
document.getElementById('panel-link').href = CONFIG.panelUrl;

document.getElementById('win-meta').textContent = CONFIG.windows.arch;
document.getElementById('android-meta').textContent = CONFIG.android.arch;

const releasesUrl = `https://github.com/${CONFIG.github.repository}/releases`;
document.getElementById('releases-link').href = releasesUrl;

// 限定架构和包类型，避免误选 ARM Windows 包、更新文件或校验文件。
const downloads = [
    { id: 'win-link', matches: name => /windows/i.test(name) && /(?:setup|installer)/i.test(name) && /x64/i.test(name) && /\.(?:exe|msi)$/i.test(name) },
    { id: 'win-portable-link', matches: name => /windows/i.test(name) && /(?:standalone|portable)/i.test(name) && /x64/i.test(name) && /\.(?:zip|7z|exe)$/i.test(name) },
    { id: 'android-link', matches: name => /(?:arm64|aarch64|universal)/i.test(name) && /\.apk$/i.test(name) }
];

async function loadLatestRelease() {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 12000);
    const status = document.getElementById('release-status');

    try {
        // 由 GitHub 返回最新正式版，跳过草稿和测试版。
        const response = await fetch(`https://api.github.com/repos/${CONFIG.github.repository}/releases/latest`, {
            headers: { Accept: 'application/vnd.github+json' },
            signal: controller.signal,
            cache: 'no-cache'
        });
        if (!response.ok) throw new Error(`GitHub API: ${response.status}`);

        const release = await response.json();
        if (!release?.tag_name || !Array.isArray(release.assets)) throw new Error('没有已发布的版本');

        const version = release.tag_name;
        document.getElementById('release-subtitle').textContent = `选择对应平台的客户端，下载最新 ${version} 版本`;
        document.getElementById('win-meta').textContent = `${version} · ${CONFIG.windows.arch}`;
        document.getElementById('android-meta').textContent = `${version} · ${CONFIG.android.arch}`;

        let missing = false;
        for (const download of downloads) {
            const link = document.getElementById(download.id);
            const asset = release.assets.find(item => item.state === 'uploaded' && download.matches(item.name)
                && item.browser_download_url?.startsWith(`${releasesUrl}/download/`));
            if (asset) {
                link.href = `${CONFIG.github.downloadProxy.replace(/\/+$/, '')}/${asset.browser_download_url}`;
                link.removeAttribute('aria-disabled');
                link.removeAttribute('tabindex');
            } else {
                missing = true;
                link.textContent = '该版本暂无此安装包';
            }
        }
        status.textContent = missing ? '部分安装包尚未上传，可前往 GitHub Releases 查看。' : '下载通过 ghfast.top 加速';
    } catch (error) {
        status.textContent = '获取最新版本失败，请刷新重试，或前往 GitHub Releases 下载。';
        console.error('获取 GitHub Release 失败：', error);
    } finally {
        clearTimeout(timeout);
    }
}

loadLatestRelease();

// 简单的 UA 检测，高亮当前设备对应的卡片
const ua = navigator.userAgent.toLowerCase();
if (ua.includes('android')) {
    document.getElementById('card-android').classList.add('recommended');
} else if (ua.includes('win')) {
    document.getElementById('card-win').classList.add('recommended');
}
