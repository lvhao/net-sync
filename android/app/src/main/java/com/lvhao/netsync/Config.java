package com.lvhao.netsync;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.Build;
import android.provider.Settings;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/** 配对信息、要同步的文件夹与本地目录映射，全部持久化在手机上。 */
public final class Config {

    public static class Pair {
        public String folderId = "";
        public String folderName = "";
        public String localDir = "";
        public long lastSync = 0;
        public String lastResult = "";
    }

    public String host = "";
    public int port = 8765;
    public String token = "";
    public String deviceId = "";
    public String deviceName = "";
    public String computerName = "";
    public List<Pair> pairs = new ArrayList<>();

    private static final String PREF = "netsync";

    public static Config load(Context ctx) {
        SharedPreferences sp = ctx.getSharedPreferences(PREF, Context.MODE_PRIVATE);
        Config c = new Config();
        c.host = sp.getString("host", "");
        c.port = sp.getInt("port", 8765);
        c.token = sp.getString("token", "");
        c.deviceId = sp.getString("deviceId", "");
        c.deviceName = systemDeviceName(ctx);
        c.computerName = sp.getString("computerName", "");   // 仅作离线时的上次已知名字
        if (c.deviceId.isEmpty()) {
            // 之前每次 Config.load 都会用时间戳生成新 ID，未保存前反复调用
            // 会让同一台手机在 Mac 端注册成多个设备。这里一次生成、立即落盘。
            c.deviceId = stableDeviceId(ctx);
            sp.edit().putString("deviceId", c.deviceId).apply();
        }
        String raw = sp.getString("pairs", "[]");
        try {
            JSONArray arr = new JSONArray(raw);
            for (int i = 0; i < arr.length(); i++) {
                JSONObject o = arr.getJSONObject(i);
                Pair p = new Pair();
                p.folderId = o.optString("folderId");
                p.folderName = o.optString("folderName");
                p.localDir = o.optString("localDir");
                p.lastSync = o.optLong("lastSync");
                p.lastResult = o.optString("lastResult");
                if (!p.folderId.isEmpty()) c.pairs.add(p);
            }
        } catch (JSONException ignored) {
        }
        return c;
    }

    public void save(Context ctx) {
        JSONArray arr = new JSONArray();
        for (Pair p : pairs) {
            JSONObject o = new JSONObject();
            try {
                o.put("folderId", p.folderId);
                o.put("folderName", p.folderName);
                o.put("localDir", p.localDir);
                o.put("lastSync", p.lastSync);
                o.put("lastResult", p.lastResult);
            } catch (JSONException ignored) {
            }
            arr.put(o);
        }
        ctx.getSharedPreferences(PREF, Context.MODE_PRIVATE).edit()
                .putString("host", host)
                .putInt("port", port)
                .putString("token", token)
                .putString("deviceId", deviceId)
                .putString("deviceName", deviceName)
                .putString("computerName", computerName)
                .putString("pairs", arr.toString())
                .apply();
    }

    /** 用户在系统设置里给手机起的名字（设置 → 关于手机 → 设备名称）。 */
    public static String systemDeviceName(Context ctx) {
        try {
            String name = Settings.Global.getString(ctx.getContentResolver(), "device_name");
            if (name == null || name.trim().isEmpty()) {
                name = Settings.Secure.getString(ctx.getContentResolver(), "bluetooth_name");
            }
            if (name == null || name.trim().isEmpty()) {
                return (Build.MANUFACTURER + " " + Build.MODEL).trim();
            }
            return name.trim();
        } catch (Exception e) {
            return (Build.MANUFACTURER + " " + Build.MODEL).trim();
        }
    }

    /** 优先用系统 ANDROID_ID，拿不到时退回随机 UUID；只生成一次后持久化。 */
    private static String stableDeviceId(Context ctx) {
        String raw = null;
        try {
            raw = Settings.Secure.getString(ctx.getContentResolver(), Settings.Secure.ANDROID_ID);
        } catch (Exception ignored) {
        }
        if (raw == null || raw.trim().isEmpty()) {
            raw = UUID.randomUUID().toString().replace("-", "");
        }
        return "android-" + raw.trim();
    }

    public boolean paired() {
        return !host.isEmpty() && !token.isEmpty();
    }

    public Pair pair(String folderId) {
        for (Pair p : pairs) if (p.folderId.equals(folderId)) return p;
        return null;
    }

    public String baseUrl() {
        String h = host.contains(":") ? "[" + host + "]" : host;
        return "http://" + h + ":" + port;
    }
}
