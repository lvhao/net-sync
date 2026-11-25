package com.lvhao.netsync;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.view.LayoutInflater;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;
import android.widget.Toast;

import java.io.File;
import java.util.ArrayList;
import java.util.List;

/** 主界面：扫码配对 → 显示电脑文件夹 → 选手机目录 → 一键同步。 */
public class MainActivity extends Activity {

    private Config cfg;
    private TextView status, detail;
    private TextView computerNameView, computerSub, phoneName, phoneSub, linkLabel, folderCount;
    private TextView emptyTitle, emptyHint, lastSync;
    private View linkOnline, statusDot;
    private LinearLayout folderList;
    private Button scanBtn, syncBtn;
    private ProgressBar progress;
    private final Handler ui = new Handler(Looper.getMainLooper());
    private TextView noticeView;
    private final Runnable hideNotice = () -> {
        if (noticeView != null) noticeView.setVisibility(View.GONE);
    };
    private final List<SyncClient.RemoteFolder> remoteFolders = new ArrayList<>();
    private final List<String> remoteFolderIds = new ArrayList<>();
    private boolean hasLoadedOnce;
    private volatile boolean syncing;
    private SyncEngine currentEngine;
    private boolean autoStarted;
    private long lastAutoSync;
    private boolean inForeground;
    private boolean connected;
    private boolean pausedHint;
    private String computerName = "";
    private static final long AUTO_INTERVAL_MS = 60_000;
    private final Runnable autoTick = new Runnable() {
        @Override public void run() {
            if (inForeground && !isFinishing() && !isDestroyed()) {
                // 电脑端可能新增/移除了目录：定时对账，避免手机一直停留在旧列表
                if (cfg.paired() && !syncing) refreshFolderList(false);
                maybeAutoSync();
                ui.postDelayed(this, AUTO_INTERVAL_MS);
            }
        }
    };

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        setContentView(R.layout.activity_main);
        cfg = Config.load(this);

        status = findViewById(R.id.status);
        detail = findViewById(R.id.detail);
        folderList = findViewById(R.id.folders);
        computerNameView = findViewById(R.id.computer_name);
        computerSub = findViewById(R.id.computer_sub);
        phoneName = findViewById(R.id.phone_name);
        phoneSub = findViewById(R.id.phone_sub);
        linkLabel = findViewById(R.id.link_label);
        linkOnline = findViewById(R.id.link_online);
        folderCount = findViewById(R.id.folder_count);
        emptyTitle = findViewById(R.id.empty_title);
        emptyHint = findViewById(R.id.empty_hint);
        lastSync = findViewById(R.id.last_sync);
        statusDot = findViewById(R.id.status_dot);
        progress = findViewById(R.id.progress);
        scanBtn = findViewById(R.id.scan);
        syncBtn = findViewById(R.id.sync);

        scanBtn.setOnClickListener(v -> ScanActivity.start(this, 11));
        syncBtn.setOnClickListener(v -> syncAll());
        ui.postDelayed(autoTick, AUTO_INTERVAL_MS);
        ensureStorageAccess();
    }

    @Override
    protected void onPause() {
        super.onPause();
        inForeground = false;
        ui.removeCallbacks(autoTick);
    }

    @Override
    protected void onResume() {
        super.onResume();
        boolean wasBackground = !inForeground;
        inForeground = true;
        cfg = Config.load(this);   // deviceName 每次都从系统实时读取
        render();
        if (cfg.paired()) loadFolders();
        maybeAutoSync();
        if (wasBackground) {
            ui.removeCallbacks(autoTick);
            ui.postDelayed(autoTick, AUTO_INTERVAL_MS);
        }
    }

    @Override
    protected void onActivityResult(int code, int result, Intent data) {
        super.onActivityResult(code, result, data);
        if (code == 11 && result == RESULT_OK) {
            cfg = Config.load(this);
            loadFolders();
            ensureStorageAccess();
        }
        if (code == 12 && result == RESULT_OK) {
            render();
        }
    }

    /** light-content 状态栏在部分 ROM 上不可用，单独兜底 */
    private int color(int id) {
        return Build.VERSION.SDK_INT >= 23 ? getColor(id) : 0xFF86868B;
    }

    private void ensureStorageAccess() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            if (!Environment.isExternalStorageManager()) {
                try {
                    Intent i = new Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION);
                    i.setData(Uri.parse("package:" + getPackageName()));
                    startActivity(i);
                } catch (Exception e) {
                    startActivity(new Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION));
                }
            }
        } else if (checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE)
                != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.READ_EXTERNAL_STORAGE}, 1);
        }
    }

    // ------------------------------------------------------------ 数据加载
    private void loadFolders() { refreshFolderList(true); }

    /**
     * 拉取电脑端目录并与本地对账。
     * @param announce 是否在检测到新增目录时给出提示（后台轮询时只在真的变化后提示）
     */
    private void refreshFolderList(boolean announce) {
        final Config snapshot = cfg;
        new Thread(() -> {
            try {
                SyncClient client = new SyncClient(snapshot);
                String name = client.ping();
                List<SyncClient.RemoteFolder> folders = client.folders();
                ui.post(() -> applyFolderList(name, folders, announce));
            } catch (Exception e) {
                ui.post(() -> {
                    // 轮询失败不打断当前界面，仅首次加载时标记离线
                    if (remoteFolders.isEmpty()) {
                        connected = false;
                        pausedHint = e.getMessage() != null && e.getMessage().contains("暂停");
                        computerName = "";
                    }
                    render();
                });
            }
        }).start();
    }

    /** 电脑端目录 → 手机端：新增自动建档，移除则清理映射（不动手机文件）。 */
    private void applyFolderList(String name, List<SyncClient.RemoteFolder> folders, boolean announce) {
        computerName = name;
        if (!name.isEmpty() && !name.equals(cfg.computerName)) {
            cfg.computerName = name;
            cfg.save(this);
        }
        connected = true;
        pausedHint = false;

        List<String> known = new ArrayList<>();
        for (SyncClient.RemoteFolder f : folders) known.add(f.id);

        // 电脑端已移除的目录：清掉映射，避免“幽灵文件夹”
        List<Config.Pair> removed = new ArrayList<>();
        for (Config.Pair p : new ArrayList<>(cfg.pairs)) {
            if (!known.contains(p.folderId)) removed.add(p);
        }
        if (!removed.isEmpty()) {
            cfg.pairs.removeAll(removed);
            cfg.save(this);
        }

        // 识别新增：只在已经加载过一次之后才算“变化”
        boolean firstLoad = !hasLoadedOnce;
        List<String> added = new ArrayList<>();
        if (!firstLoad) {
            for (SyncClient.RemoteFolder f : folders) {
                if (!remoteFolderIds.contains(f.id)) added.add(f.name);
            }
        }
        hasLoadedOnce = true;

        remoteFolders.clear();
        remoteFolders.addAll(folders);
        remoteFolderIds.clear();
        remoteFolderIds.addAll(known);

        autoAssignFolders();
        render();

        if (!added.isEmpty()) {
            String msg = added.size() == 1
                    ? "电脑新增了「" + added.get(0) + "」"
                    : "电脑新增了 " + added.size() + " 个文件夹";
            note(msg + " · 已加入同步", R.color.ok);
        } else if (!removed.isEmpty()) {
            note("电脑移除了 " + removed.size() + " 个文件夹，手机文件未删除", R.color.faint);
        }
    }

    /** 目录变化等提醒：显示在标题下方，几秒后回落。 */
    private void note(String text, int colorRes) {
        if (noticeView == null) noticeView = findViewById(R.id.notice);
        noticeView.setVisibility(View.VISIBLE);
        noticeView.setText(text);
        noticeView.setTextColor(color(colorRes));
        ui.removeCallbacks(hideNotice);
        ui.postDelayed(hideNotice, 5200);
    }

    private void render() {
        boolean paired = cfg.paired();
        if (!paired) {
            status.setText("扫描电脑上的二维码，建立直连");
        } else if (!connected) {
            status.setText(pausedHint ? "电脑端已暂停这台设备的同步"
                                      : "已配对 · 正在寻找 " + cfg.host);
        } else {
            status.setText("直连已建立 · 文件在这台手机和电脑之间自动同步");
        }

        computerNameView.setText(connected && !computerName.isEmpty()
                ? computerName
                : (cfg.computerName.isEmpty() ? "电脑" : cfg.computerName));
        phoneName.setText(cfg.deviceName.isEmpty() ? "这台手机" : cfg.deviceName);
        computerSub.setText(paired ? (connected ? cfg.host : "未找到设备") : "等待配对");
        phoneSub.setText(paired ? (connected ? "已连接" : "已配对 · 离线") : "未配对");
        statusDot.setBackgroundResource(connected ? R.drawable.dot_online : R.drawable.dot_offline);
        linkLabel.setText(paired && connected ? "直连" : (paired ? "离线" : "未连接"));
        linkOnline.setBackgroundColor(color(paired && connected ? R.color.faint : R.color.line));

        folderCount.setText(String.valueOf(remoteFolders.size()));
        findViewById(R.id.empty).setVisibility(remoteFolders.isEmpty() ? View.VISIBLE : View.GONE);
        if (remoteFolders.isEmpty()) {
            emptyTitle.setText(paired ? "还没有读取到文件夹" : "还没有配对过电脑");
            emptyHint.setText(paired ? "确认电脑上的「内网同步」已打开"
                                     : "点上方按钮扫描 Mac 窗口里的二维码");
        }

        folderList.removeAllViews();
        boolean allReady = !remoteFolders.isEmpty();
        for (SyncClient.RemoteFolder f : remoteFolders) {
            Config.Pair p = cfg.pair(f.id);
            View row = LayoutInflater.from(this).inflate(R.layout.item_folder, folderList, false);
            ((TextView) row.findViewById(R.id.name)).setText(f.name);
            TextView sub = row.findViewById(R.id.sub);
            TextView action = row.findViewById(R.id.action);
            TextView state = row.findViewById(R.id.state);

            if (p != null && !p.localDir.isEmpty()) {
                sub.setText(p.localDir);
                action.setText("更改");
                if (!p.lastResult.isEmpty()) {
                    sub.setText(p.localDir + "\n" + p.lastResult);
                }
                state.setText(connected ? "已同步" : "待同步");
                state.setTextColor(color(connected ? R.color.muted : R.color.faint));
            } else {
                sub.setText("尚未选择手机上的存放位置");
                action.setText("选择");
                state.setText("未配置");
                state.setTextColor(color(R.color.faint));
                allReady = false;
            }
            final Config.Pair current = p;
            View.OnClickListener pick = v -> {
                Intent i = new Intent(this, FolderPicker.class);
                i.putExtra(FolderPicker.EXTRA_FOLDER_ID, f.id);
                i.putExtra(FolderPicker.EXTRA_FOLDER_NAME, f.name);
                if (current != null) i.putExtra(FolderPicker.EXTRA_START, current.localDir);
                startActivityForResult(i, 12);
            };
            row.setOnClickListener(pick);
            action.setOnClickListener(pick);
            folderList.addView(row);
        }
        long newest = 0;
        for (Config.Pair p : cfg.pairs) newest = Math.max(newest, p.lastSync);
        if (paired && newest > 0) {
            lastSync.setVisibility(View.VISIBLE);
            lastSync.setText(syncing ? "正在同步…" : "上次同步 " + ago(newest));
        } else {
            lastSync.setVisibility(View.GONE);
        }

        syncBtn.setEnabled(allReady && !syncing);
        syncBtn.setText(syncing ? "正在同步…" : "立即同步");
        syncBtn.setVisibility(paired && !remoteFolders.isEmpty() ? View.VISIBLE : View.GONE);
        scanBtn.setText(paired ? "重新扫码配对" : "扫码添加电脑");
    }

    /** 打开 App、回到前台、连上电脑时自动同步，无需手动点。 */
    /** 没选过目录的文件夹，自动落到 /sdcard/<文件夹名>，省掉手动选目录这一步。 */
    private void autoAssignFolders() {
        boolean changed = false;
        File sdcard = Environment.getExternalStorageDirectory();
        for (SyncClient.RemoteFolder f : remoteFolders) {
            Config.Pair p = cfg.pair(f.id);
            if (p != null && !p.localDir.isEmpty()) continue;
            File dir = new File(sdcard, f.name);
            if (!dir.exists() && !dir.mkdirs()) continue;
            if (p == null) {
                p = new Config.Pair();
                p.folderId = f.id;
                p.folderName = f.name;
                cfg.pairs.add(p);
            }
            p.localDir = dir.getAbsolutePath();
            changed = true;
        }
        if (changed) {
            cfg.save(this);
            render();
        }
    }

    private void maybeAutoSync() {
        if (syncing || !cfg.paired()) return;
        boolean ready = false;
        for (SyncClient.RemoteFolder f : remoteFolders) {
            Config.Pair p = cfg.pair(f.id);
            if (p != null && !p.localDir.isEmpty()) { ready = true; break; }
        }
        if (!ready) return;
        if (autoStarted && System.currentTimeMillis() - lastAutoSync < 10_000) return;
        autoStarted = true;
        lastAutoSync = System.currentTimeMillis();
        syncAll();
    }

    // ------------------------------------------------------------ 同步
    private void syncAll() {
        if (syncing) return;
        syncing = true;
        progress.setVisibility(View.VISIBLE);
        progress.setProgress(0);
        render();

        new Thread(() -> {
            StringBuilder summary = new StringBuilder();
            for (SyncClient.RemoteFolder f : remoteFolders) {
                Config.Pair p = cfg.pair(f.id);
                if (p == null || p.localDir.isEmpty()) continue;
                ui.post(() -> {
                    detail.setTextColor(color(R.color.muted));
                    detail.setText("正在同步「" + f.name + "」…");
                });
                try {
                    currentEngine = new SyncEngine(cfg, f.id, p.localDir);
                    SyncEngine.Stats st = currentEngine.run((msg, done, total) -> ui.post(() -> {
                        detail.setText(f.name + " · " + msg);
                        progress.setMax(Math.max(total, 1));
                        progress.setProgress(done);
                    }));
                    p.lastSync = System.currentTimeMillis();
                    p.lastResult = st.toString();
                    summary.append(f.name).append("：").append(st.toString()).append('\n');
                } catch (Exception e) {
                    p.lastResult = "失败：" + e.getMessage();
                    summary.append(f.name).append("：失败 ").append(e.getMessage()).append('\n');
                }
            }
            cfg.save(this);
            String text = summary.toString().trim();
            ui.post(() -> {
                syncing = false;
                currentEngine = null;
                progress.setVisibility(View.GONE);
                detail.setTextColor(color(R.color.faint));
                detail.setText(text.isEmpty() ? "没有可同步的文件夹" : text);
                render();
            });
        }).start();
    }

    @Override
    public void onBackPressed() {
        if (currentEngine != null && syncing) {
            currentEngine.cancel();
            toast("正在停止…");
            return;
        }
        super.onBackPressed();
    }

    private String ago(long millis) {
        long diff = Math.max(0, System.currentTimeMillis() - millis);
        long min = diff / 60_000;
        if (min < 1) return "刚刚";
        if (min < 60) return min + " 分钟前";
        long h = min / 60;
        if (h < 24) return h + " 小时前";
        return (h / 24) + " 天前";
    }

    private void toast(String s) {
        Toast.makeText(this, s, Toast.LENGTH_SHORT).show();
    }
}
