package com.lvhao.netsync;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

/** 与 Mac 端 NetSync 服务通信。 */
public class SyncClient {

    public static class RemoteFile {
        public String path;
        public long size;
        public long mtime;
        public String hash;
    }

    public static class RemoteFolder {
        public String id;
        public String name;
        public boolean exists;
    }

    private final Config cfg;

    public SyncClient(Config cfg) {
        this.cfg = cfg;
    }

    private HttpURLConnection open(String path, String method) throws IOException {
        URL url = new URL(cfg.baseUrl() + path);
        HttpURLConnection c = (HttpURLConnection) url.openConnection();
        c.setRequestMethod(method);
        c.setRequestProperty("X-Sync-Token", cfg.token);
        c.setRequestProperty("X-Device-Id", cfg.deviceId);
        c.setRequestProperty("X-Device-Name", cfg.deviceName);
        c.setConnectTimeout(8000);
        c.setReadTimeout(180000);
        return c;
    }

    private static String enc(String p) throws IOException {
        return URLEncoder.encode(p, "UTF-8").replace("+", "%20");
    }

    private String read(InputStream in) throws IOException {
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        byte[] buf = new byte[8192];
        int n;
        while ((n = in.read(buf)) > 0) bos.write(buf, 0, n);
        return new String(bos.toByteArray(), StandardCharsets.UTF_8);
    }

    private JSONObject getJson(String path) throws IOException {
        HttpURLConnection c = open(path, "GET");
        try {
            int code = c.getResponseCode();
            if (code == 403) throw new IOException("配对已失效，请重新扫码");
            if (code == 423) throw new IOException("电脑端已暂停这台设备的同步");
            if (code != 200) throw new IOException("HTTP " + code);
            try {
                return new JSONObject(read(c.getInputStream()));
            } catch (JSONException e) {
                throw new IOException("返回格式错误", e);
            }
        } finally {
            c.disconnect();
        }
    }

    /** 验证连通性，返回 Mac 主机名。 */
    public String ping() throws IOException {
        return getJson("/api/ping").optString("name", "Mac");
    }

    public List<RemoteFolder> folders() throws IOException {
        JSONArray arr;
        try {
            arr = getJson("/api/folders").getJSONArray("folders");
        } catch (JSONException e) {
            throw new IOException("文件夹列表格式错误", e);
        }
        List<RemoteFolder> out = new ArrayList<>();
        try {
            for (int i = 0; i < arr.length(); i++) {
                JSONObject o = arr.getJSONObject(i);
                RemoteFolder f = new RemoteFolder();
                f.id = o.getString("id");
                f.name = o.optString("name", f.id);
                f.exists = o.optBoolean("exists", true);
                out.add(f);
            }
        } catch (JSONException e) {
            throw new IOException("文件夹列表格式错误", e);
        }
        return out;
    }

    public List<RemoteFile> manifest(String folderId) throws IOException {
        JSONArray arr;
        try {
            arr = getJson("/api/manifest?folder=" + enc(folderId)).getJSONArray("files");
        } catch (JSONException e) {
            throw new IOException("清单格式错误", e);
        }
        List<RemoteFile> out = new ArrayList<>();
        try {
            for (int i = 0; i < arr.length(); i++) {
                JSONObject o = arr.getJSONObject(i);
                RemoteFile f = new RemoteFile();
                f.path = o.getString("p");
                f.size = o.getLong("s");
                f.mtime = o.getLong("m");
                f.hash = o.getString("h");
                out.add(f);
            }
        } catch (JSONException e) {
            throw new IOException("清单格式错误", e);
        }
        return out;
    }

    public void download(String folderId, String path, File target) throws IOException {
        HttpURLConnection c = open("/api/file?folder=" + enc(folderId) + "&p=" + enc(path), "GET");
        try {
            int code = c.getResponseCode();
            if (code != 200) throw new IOException("下载失败 HTTP " + code);
            File parent = target.getParentFile();
            if (parent != null && !parent.exists() && !parent.mkdirs()) {
                throw new IOException("无法创建目录 " + parent);
            }
            File tmp = new File(target.getPath() + ".part");
            try (InputStream in = new BufferedInputStream(c.getInputStream());
                 OutputStream out = new FileOutputStream(tmp)) {
                byte[] buf = new byte[65536];
                int n;
                while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
            }
            if (target.exists() && !target.delete()) throw new IOException("无法覆盖 " + target);
            if (!tmp.renameTo(target)) throw new IOException("无法写入 " + target);
        } finally {
            c.disconnect();
        }
    }

    public void upload(String folderId, String path, File source, long mtime) throws IOException {
        HttpURLConnection c = open("/api/file?folder=" + enc(folderId) + "&p=" + enc(path), "PUT");
        c.setDoOutput(true);
        c.setFixedLengthStreamingMode(source.length());
        c.setRequestProperty("Content-Type", "application/octet-stream");
        c.setRequestProperty("X-Mtime", String.valueOf(mtime));
        try {
            try (OutputStream out = c.getOutputStream();
                 InputStream in = new BufferedInputStream(new FileInputStream(source))) {
                byte[] buf = new byte[65536];
                int n;
                while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
            }
            int code = c.getResponseCode();
            if (code != 200) throw new IOException("上传失败 HTTP " + code);
        } finally {
            c.disconnect();
        }
    }

    public void delete(String folderId, String path) throws IOException {
        HttpURLConnection c = open("/api/file?folder=" + enc(folderId) + "&p=" + enc(path), "DELETE");
        try {
            c.getResponseCode();
        } finally {
            c.disconnect();
        }
    }
}
