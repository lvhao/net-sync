package com.lvhao.netsync;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.security.MessageDigest;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * 单个文件夹的双向同步，采用「基线 + 三方比对」：
 * 用上次同步留下的内容指纹，判断每一侧是新增、修改还是删除。
 */
public class SyncEngine {

    public interface Progress {
        void onStep(String message, int done, int total);
    }

    public static class Stats {
        public int uploaded, downloaded, deleted, conflicts, unchanged, failed;
        public boolean aborted;

        @Override public String toString() {
            if (aborted) return "已中断";
            if (uploaded + downloaded + deleted + conflicts + failed == 0) return "已是最新";
            StringBuilder sb = new StringBuilder();
            if (downloaded > 0) sb.append("下载 ").append(downloaded).append("  ");
            if (uploaded > 0) sb.append("上传 ").append(uploaded).append("  ");
            if (deleted > 0) sb.append("删除 ").append(deleted).append("  ");
            if (conflicts > 0) sb.append("冲突 ").append(conflicts).append("  ");
            if (failed > 0) sb.append("失败 ").append(failed);
            return sb.toString().trim();
        }
    }

    private final SyncClient client;
    private final String folderId;
    private final File root;
    private volatile boolean cancelled;

    public SyncEngine(Config cfg, String folderId, String localDir) {
        this.client = new SyncClient(cfg);
        this.folderId = folderId;
        this.root = new File(localDir);
    }

    public void cancel() {
        cancelled = true;
    }

    public static String sha256(File f) throws IOException {
        try (FileInputStream in = new FileInputStream(f)) {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] buf = new byte[65536];
            int n;
            while ((n = in.read(buf)) > 0) md.update(buf, 0, n);
            StringBuilder sb = new StringBuilder();
            for (byte b : md.digest()) sb.append(String.format("%02x", b));
            return sb.toString();
        } catch (Exception e) {
            throw new IOException(e);
        }
    }

    private Map<String, File> scanLocal() {
        Map<String, File> out = new HashMap<>();
        if (!root.isDirectory()) return out;
        collect(root, "", out);
        return out;
    }

    private void collect(File dir, String prefix, Map<String, File> out) {
        File[] items = dir.listFiles();
        if (items == null) return;
        for (File f : items) {
            String name = f.getName();
            if (name.startsWith(".netsync-") || name.endsWith(".part") || name.endsWith(".netsync-tmp")) {
                continue;
            }
            String rel = prefix.isEmpty() ? name : prefix + "/" + name;
            if (f.isDirectory()) {
                collect(f, rel, out);
            } else if (f.isFile()) {
                out.put(rel, f);
            }
        }
    }

    public Stats run(Progress progress) throws IOException {
        Stats s = new Stats();
        if (!root.exists() && !root.mkdirs()) throw new IOException("无法创建目录: " + root);
        if (cancelled) { s.aborted = true; return s; }

        progress.onStep("读取电脑端文件列表…", 0, 1);
        List<SyncClient.RemoteFile> remoteList = client.manifest(folderId);
        Map<String, SyncClient.RemoteFile> remote = new HashMap<>();
        for (SyncClient.RemoteFile f : remoteList) remote.put(f.path, f);

        Map<String, File> local = scanLocal();
        Map<String, SyncState.Entry> base = SyncState.load(root);
        Map<String, SyncState.Entry> after = new HashMap<>();

        Set<String> all = new HashSet<>();
        all.addAll(remote.keySet());
        all.addAll(local.keySet());
        int total = all.size();
        int done = 0;

        for (String rel : all) {
            if (cancelled) { s.aborted = true; break; }
            SyncClient.RemoteFile r = remote.get(rel);
            File l = local.get(rel);
            SyncState.Entry b = base.get(rel);
            done++;
            try {
                if (r != null && l != null) {
                    long localSize = l.length();
                    long localMtime = l.lastModified();

                    // 快路径：size/mtime 都与基线一致，且两端 size/mtime 相同 → 直接认为未变
                    // （macOS 与 Android 的 mtime 精度不同，容忍 2 秒误差）
                    boolean sameAsBase = b != null
                            && b.size == localSize
                            && Math.abs(b.mtime - localMtime) <= 2000;
                    if (sameAsBase
                            && r.size == localSize
                            && Math.abs(r.mtime - localMtime) <= 2000
                            && r.hash.equals(b.hash)) {
                        s.unchanged++;
                        after.put(rel, b);
                        continue;
                    }

                    String localHash = sha256(l);
                    if (localHash.equals(r.hash)) {
                        s.unchanged++;
                        after.put(rel, new SyncState.Entry(localSize, localMtime, localHash));
                        continue;
                    }
                    boolean localChanged = b == null || !localHash.equals(b.hash);
                    boolean remoteChanged = b == null || !r.hash.equals(b.hash);

                    if (localChanged && !remoteChanged) {
                        client.upload(folderId, rel, l, localMtime);
                        s.uploaded++;
                        after.put(rel, new SyncState.Entry(localSize, localMtime, localHash));
                    } else if (!localChanged && remoteChanged) {
                        client.download(folderId, rel, l);
                        l.setLastModified(r.mtime);
                        s.downloaded++;
                        after.put(rel, new SyncState.Entry(l.length(), l.lastModified(), r.hash));
                    } else if (!localChanged) {
                        // 基线缺失或已陈旧，但两边内容不同：按较新一侧处理
                        if (l.lastModified() >= r.mtime) {
                            client.upload(folderId, rel, l, localMtime);
                            s.uploaded++;
                            after.put(rel, new SyncState.Entry(localSize, localMtime, localHash));
                        } else {
                            client.download(folderId, rel, l);
                            l.setLastModified(r.mtime);
                            s.downloaded++;
                            after.put(rel, new SyncState.Entry(l.length(), l.lastModified(), r.hash));
                        }
                    } else {
                        // 两边都改过：保留较新，另一份存成副本
                        copy(l, new File(root, rel + ".conflict-" + l.lastModified()));
                        if (l.lastModified() >= r.mtime) {
                            client.upload(folderId, rel, l, localMtime);
                            s.uploaded++;
                            after.put(rel, new SyncState.Entry(localSize, localMtime, localHash));
                        } else {
                            client.download(folderId, rel, l);
                            l.setLastModified(r.mtime);
                            s.downloaded++;
                            after.put(rel, new SyncState.Entry(l.length(), l.lastModified(), r.hash));
                        }
                        s.conflicts++;
                    }
                } else if (r != null) {
                    if (b != null) {
                        // 上次同步时还在、现在手机上没有 → 用户在手机上删除
                        client.delete(folderId, rel);
                        s.deleted++;
                    } else {
                        File target = new File(root, rel);
                        client.download(folderId, rel, target);
                        target.setLastModified(r.mtime);
                        s.downloaded++;
                        after.put(rel, new SyncState.Entry(target.length(), target.lastModified(), r.hash));
                    }
                } else {
                    if (b != null) {
                        // 上次同步时还在、现在电脑上没有 → 在电脑上删除
                        if (l.delete()) s.deleted++;
                    } else {
                        // 电脑上没有、手机上有，且无基线 → 新增文件，上传
                        String localHash = sha256(l);
                        long size = l.length();
                        long mtime = l.lastModified();
                        client.upload(folderId, rel, l, mtime);
                        s.uploaded++;
                        after.put(rel, new SyncState.Entry(size, mtime, localHash));
                    }
                }
            } catch (IOException e) {
                s.failed++;
                progress.onStep("失败：" + rel + " — " + e.getMessage(), done, total);
                if (b != null) after.put(rel, b);
            }
            if (done % 5 == 0 || done == total) {
                progress.onStep("同步中 " + done + "/" + total, done, total);
            }
        }

        if (!s.aborted) SyncState.save(root, after);
        progress.onStep(s.toString(), total, total);
        return s;
    }

    private SyncState.Entry entry(File f, String hash) {
        return new SyncState.Entry(f.length(), f.lastModified(), hash);
    }

    private void copy(File src, File dst) throws IOException {
        File parent = dst.getParentFile();
        if (parent != null) parent.mkdirs();
        try (FileInputStream in = new FileInputStream(src);
             FileOutputStream out = new FileOutputStream(dst)) {
            byte[] buf = new byte[65536];
            int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
        }
    }
}
