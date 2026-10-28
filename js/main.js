// 渲染配置信息
document.title = CONFIG.appName;
document.getElementById('app-title').textContent = CONFIG.appName;
document.getElementById('panel-link').href = CONFIG.panelUrl;

document.getElementById('win-meta').textContent = `${CONFIG.windows.version} · ${CONFIG.windows.arch}`;
document.getElementById('win-link').href = CONFIG.windows.url;
document.getElementById('win-portable-link').href = CONFIG.windows.portableUrl;

document.getElementById('android-meta').textContent = `${CONFIG.android.version} · ${CONFIG.android.arch}`;
document.getElementById('android-link').href = CONFIG.android.url;

// 简单的 UA 检测，高亮当前设备对应的卡片
const ua = navigator.userAgent.toLowerCase();
if (ua.includes('android')) {
    document.getElementById('card-android').classList.add('recommended');
} else if (ua.includes('win')) {
    document.getElementById('card-win').classList.add('recommended');
}
