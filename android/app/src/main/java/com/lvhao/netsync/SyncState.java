package com.lvhao.netsync;

import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.HashMap;
import java.util.Map;

/**
 * 上次同步完成时，手机端每个文件的内容指纹（size / mtime / sha256）。
 *
 * 有了“基线”，就能区分三种情况：
 *   - 只有手机改过   → 上传
 *   - 只有电脑改过   → 下载
 *   - 两边都改过     → 冲突，保留较新，另一份存副本
 * 也能识别“手机端删除了文件”，而不会把同步中断留下的新文件误删。
 */
final class SyncState {

    private static final String FILENAME = ".netsync-state";
    private static final String VERSION = "v3";

    static final class Entry {
        final long size;
        final long mtime;
        final String hash;

        Entry(long size, long mtime, String hash) {
            this.size = size;
            this.mtime = mtime;
            this.hash = hash;
        }
    }

    private SyncState() {
    }

    static File file(File root) {
        return new File(root, FILENAME);
    }

    static Map<String, Entry> load(File root) {
        Map<String, Entry> out = new HashMap<>();
        File f = file(root);
        if (!f.isFile()) return out;
        String text;
        try {
            text = new String(Files.readAllBytes(f.toPath()), StandardCharsets.UTF_8);
        } catch (IOException e) {
            return out;
        }
        String[] lines = text.split("\n");
        if (lines.length == 0 || !VERSION.equals(lines[0].trim())) return out;
        for (int i = 1; i < lines.length; i++) {
            String line = lines[i].trim();
            if (line.isEmpty()) continue;
            String[] p = line.split("\t");
            if (p.length != 4) continue;
            try {
                out.put(p[0], new Entry(Long.parseLong(p[1]), Long.parseLong(p[2]), p[3]));
            } catch (NumberFormatException ignored) {
            }
        }
        return out;
    }

    static void save(File root, Map<String, Entry> entries) {
        StringBuilder sb = new StringBuilder(VERSION).append('\n');
        for (Map.Entry<String, Entry> e : entries.entrySet()) {
            Entry v = e.getValue();
            sb.append(e.getKey()).append('\t').append(v.size).append('\t')
              .append(v.mtime).append('\t').append(v.hash).append('\n');
        }
        try {
            Files.write(file(root).toPath(), sb.toString().getBytes(StandardCharsets.UTF_8));
        } catch (IOException ignored) {
        }
    }
}
