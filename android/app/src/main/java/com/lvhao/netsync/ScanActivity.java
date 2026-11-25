package com.lvhao.netsync;

import android.Manifest;
import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.util.Log;
import android.view.View;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.NonNull;
import androidx.camera.core.CameraSelector;
import androidx.camera.core.ImageAnalysis;
import androidx.camera.core.ImageProxy;
import androidx.camera.core.Preview;
import androidx.camera.lifecycle.ProcessCameraProvider;
import androidx.camera.view.PreviewView;
import androidx.core.content.ContextCompat;
import androidx.lifecycle.Lifecycle;
import androidx.lifecycle.LifecycleOwner;
import androidx.lifecycle.LifecycleRegistry;

import com.google.common.util.concurrent.ListenableFuture;
import com.google.zxing.BarcodeFormat;
import com.google.zxing.BinaryBitmap;
import com.google.zxing.DecodeHintType;
import com.google.zxing.MultiFormatReader;
import com.google.zxing.PlanarYUVLuminanceSource;
import com.google.zxing.Result;
import com.google.zxing.common.HybridBinarizer;

import org.json.JSONObject;

import java.util.Collections;
import java.util.EnumMap;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * 扫码配对。
 *
 * 用 CameraX（主流做法）：
 *  - PreviewView 负责预览，scaleType=fillCenter 自动等比裁切，不会拉伸；
 *  - ImageAnalysis 提供已旋转到显示方向的 YUV 帧，ZXing 不需要再自己算旋转。
 */
public class ScanActivity extends Activity {

    private static final String TAG = "NetSyncScan";

    private PreviewView preview;
    private TextView hint;
    private ExecutorService analysisExecutor;
    private ProcessCameraProvider cameraProvider;
    private final MultiFormatReader zxing = new MultiFormatReader();
    private volatile boolean decoding;
    private volatile boolean done;
    private int frameCount;
    private final CameraLifecycle cameraLifecycle = new CameraLifecycle();

    /** 普通 Activity 不是 LifecycleOwner，这里用一个轻量适配器把生命周期转给 CameraX。 */
    private static final class CameraLifecycle implements LifecycleOwner {
        private final LifecycleRegistry registry = new LifecycleRegistry(this);

        @NonNull
        @Override
        public Lifecycle getLifecycle() {
            return registry;
        }

        void move(Lifecycle.Event event) {
            if (registry.getCurrentState() == Lifecycle.State.DESTROYED) return;
            registry.handleLifecycleEvent(event);
        }
    }

    public static void start(Activity from, int requestCode) {
        from.startActivityForResult(new Intent(from, ScanActivity.class), requestCode);
    }

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        setContentView(R.layout.activity_scan);
        preview = findViewById(R.id.preview);
        hint = findViewById(R.id.hint);
        analysisExecutor = Executors.newSingleThreadExecutor();
        cameraLifecycle.move(Lifecycle.Event.ON_CREATE);

        Map<DecodeHintType, Object> hints = new EnumMap<>(DecodeHintType.class);
        hints.put(DecodeHintType.POSSIBLE_FORMATS, Collections.singletonList(BarcodeFormat.QR_CODE));
        hints.put(DecodeHintType.TRY_HARDER, Boolean.TRUE);
        zxing.setHints(hints);

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA)
                != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.CAMERA}, 7);
        } else {
            startCamera();
        }
    }

    private void startCamera() {
        final ListenableFuture<ProcessCameraProvider> future =
                ProcessCameraProvider.getInstance(this);
        future.addListener(() -> {
            try {
                cameraProvider = future.get();
                bindUseCases();
            } catch (Exception e) {
                Log.e(TAG, "camera provider failed", e);
                toast("相机启动失败：" + e.getMessage());
            }
        }, ContextCompat.getMainExecutor(this));
    }

    private void bindUseCases() {
        if (cameraProvider == null) return;
        cameraProvider.unbindAll();

        Preview previewUseCase = new Preview.Builder().build();
        previewUseCase.setSurfaceProvider(preview.getSurfaceProvider());

        ImageAnalysis analysis = new ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_YUV_420_888)
                .build();
        analysis.setAnalyzer(analysisExecutor, this::analyze);

        try {
            cameraProvider.bindToLifecycle(cameraLifecycle,
                    CameraSelector.DEFAULT_BACK_CAMERA, previewUseCase, analysis);
            hint.setText("把电脑上的二维码放进取景框…");
            Log.i(TAG, "camera bound, hasCamera=" + previewUseCase.getResolutionInfo());
        } catch (Exception e) {
            Log.e(TAG, "bind failed", e);
            hint.setText("无法打开相机：" + e.getMessage());
            toast("无法打开后置相机：" + e.getMessage());
        }
    }

    private void analyze(@NonNull ImageProxy image) {
        if (decoding || done) {
            image.close();
            return;
        }
        decoding = true;
        try {
            byte[] data = toLuma(image);
            if (data == null) return;

            int w = image.getWidth();
            int h = image.getHeight();

            // ImageAnalysis 默认给的是传感器方向的原始帧（通常是横躺的），
            // 必须按 rotationDegrees 转正，否则 ZXing 看到的是躺倒的二维码。
            int degrees = image.getImageInfo().getRotationDegrees();
            if (frameCount++ % 30 == 0) {
                Log.i(TAG, "frame " + frameCount + " " + w + "x" + h + " rot=" + degrees);
            }
            if (degrees == 90 || degrees == 270) {
                data = rotateLuma(data, w, h, degrees);
                int tmp = w;
                w = h;
                h = tmp;
            } else if (degrees == 180) {
                data = rotateLuma(data, w, h, 180);
            }

            if (!tryDecode(data, w, h)) {
                // 兜底：万一方向判断有偏差，再试一次转 90°
                byte[] alt = rotateLuma(data, w, h, 90);
                tryDecode(alt, h, w);
            }
        } finally {
            decoding = false;
            image.close();
        }
    }

    private boolean tryDecode(byte[] luma, int w, int h) {
        PlanarYUVLuminanceSource src =
                new PlanarYUVLuminanceSource(luma, w, h, 0, 0, w, h, false);
        try {
            Result result = zxing.decodeWithState(new BinaryBitmap(new HybridBinarizer(src)));
            if (result != null) {
                Log.i(TAG, "decoded: " + result.getText());
                handle(result.getText());
                return true;
            }
        } catch (Exception ignored) {
            // 这一帧没识别到，继续下一帧
        } finally {
            zxing.reset();
        }
        return false;
    }

    /** 按 90/180/270 度顺时针旋转灰度图。 */
    private byte[] rotateLuma(byte[] src, int w, int h, int degrees) {
        byte[] out;
        if (degrees == 90) {
            out = new byte[src.length];
            for (int y = 0; y < w; y++) {
                for (int x = 0; x < h; x++) {
                    out[y * h + x] = src[(h - 1 - x) * w + y];
                }
            }
            return out;
        }
        if (degrees == 270) {
            out = new byte[src.length];
            for (int y = 0; y < w; y++) {
                for (int x = 0; x < h; x++) {
                    out[y * h + x] = src[x * w + (w - 1 - y)];
                }
            }
            return out;
        }
        if (degrees == 180) {
            out = new byte[src.length];
            for (int i = 0; i < src.length; i++) out[i] = src[src.length - 1 - i];
            return out;
        }
        return src;
    }

    /** 把 ImageProxy 的 Y 平面拷成紧凑数组（处理 rowStride 填充）。 */
    private byte[] toLuma(ImageProxy image) {
        if (image.getPlanes().length == 0) return null;
        java.nio.ByteBuffer buffer = image.getPlanes()[0].getBuffer();
        int rowStride = image.getPlanes()[0].getRowStride();
        int pixelStride = image.getPlanes()[0].getPixelStride();
        int w = image.getWidth();
        int h = image.getHeight();
        byte[] out = new byte[w * h];

        if (pixelStride == 1 && rowStride == w) {
            buffer.get(out, 0, Math.min(out.length, buffer.remaining()));
            return out;
        }

        byte[] row = new byte[rowStride];
        for (int y = 0; y < h; y++) {
            int len = Math.min(rowStride, buffer.remaining());
            if (len <= 0) break;
            buffer.get(row, 0, len);
            for (int x = 0; x < w; x++) {
                int idx = x * pixelStride;
                if (idx >= len) break;
                out[y * w + x] = row[idx];
            }
        }
        return out;
    }

    /** 扫码结果：既支持旧的 JSON 码，也支持现在的 http://host:port/pair 链接。 */
    private void handle(String raw) {
        if (done) return;
        final String payload = raw.trim();

        // 旧格式：{"v":2,"host":...,"token":...}
        if (payload.startsWith("{")) {
            try {
                JSONObject o = new JSONObject(payload);
                finishPairing(o.getString("host"), o.optInt("port", 8765), o.getString("token"));
            } catch (Exception ignored) {
                Log.d(TAG, "ignored QR: " + payload);
            }
            return;
        }

        // 新格式：落地页链接，向电脑换回配对信息
        java.net.URL url;
        try {
            url = new java.net.URL(payload);
        } catch (Exception e) {
            Log.d(TAG, "ignored QR: " + payload);
            return;
        }
        String scheme = url.getProtocol();
        if (!"http".equals(scheme) && !"https".equals(scheme)) {
            Log.d(TAG, "ignored QR: " + payload);
            return;
        }
        final String host = url.getHost();
        final int port = url.getPort() > 0 ? url.getPort() : 8765;
        if (host == null || host.isEmpty()) return;

        done = true;
        hint.post(() -> hint.setText("已识别，正在连接电脑…"));
        new Thread(() -> fetchPairInfo(host, port)).start();
    }

    /** 从 /api/pair 取回 token，完成配对。 */
    private void fetchPairInfo(String host, int port) {
        java.net.HttpURLConnection c = null;
        try {
            java.net.URL u = new java.net.URL("http://" + host + ":" + port + "/api/pair");
            c = (java.net.HttpURLConnection) u.openConnection();
            c.setConnectTimeout(6000);
            c.setReadTimeout(6000);
            int code = c.getResponseCode();
            if (code != 200) throw new java.io.IOException("HTTP " + code);
            java.io.ByteArrayOutputStream bos = new java.io.ByteArrayOutputStream();
            try (java.io.InputStream in = c.getInputStream()) {
                byte[] buf = new byte[4096];
                int n;
                while ((n = in.read(buf)) > 0) bos.write(buf, 0, n);
            }
            JSONObject o = new JSONObject(new String(bos.toByteArray(), "UTF-8"));
            String token = o.getString("token");
            if (token.isEmpty()) throw new java.io.IOException("empty token");
            finishPairing(o.optString("host", host), o.optInt("port", port), token);
        } catch (Exception e) {
            Log.w(TAG, "pair info failed: " + e.getMessage());
            runOnUiThread(() -> {
                done = false;
                hint.setText("连不上电脑，请确认窗口打开且在同一 Wi-Fi");
                toast("配对失败：" + e.getMessage());
            });
        } finally {
            if (c != null) c.disconnect();
        }
    }

    private void finishPairing(String host, int port, String token) {
        runOnUiThread(() -> {
            Config cfg = Config.load(this);
            boolean sameHost = host.equals(cfg.host) && port == cfg.port && token.equals(cfg.token);
            cfg.host = host;
            cfg.port = port;
            cfg.token = token;
            if (!sameHost) cfg.pairs.clear();
            cfg.save(this);

            done = true;
            hint.setText("配对成功，正在读取文件夹…");
            setResult(RESULT_OK, new Intent());
            finish();
        });
    }

    @Override
    public void onRequestPermissionsResult(int code, String[] p, int[] res) {
        if (code == 7 && res.length > 0 && res[0] == PackageManager.PERMISSION_GRANTED) {
            startCamera();
        } else if (code == 7) {
            toast("需要相机权限才能扫码");
            finish();
        }
    }

    @Override
    protected void onStart() {
        super.onStart();
        cameraLifecycle.move(Lifecycle.Event.ON_START);
    }

    @Override
    protected void onResume() {
        super.onResume();
        cameraLifecycle.move(Lifecycle.Event.ON_RESUME);
        if (cameraProvider == null
                && ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA)
                == PackageManager.PERMISSION_GRANTED) {
            startCamera();
        }
    }

    @Override
    protected void onPause() {
        cameraLifecycle.move(Lifecycle.Event.ON_PAUSE);
        super.onPause();
    }

    @Override
    protected void onStop() {
        cameraLifecycle.move(Lifecycle.Event.ON_STOP);
        super.onStop();
    }

    @Override
    protected void onDestroy() {
        if (cameraProvider != null) cameraProvider.unbindAll();
        cameraLifecycle.move(Lifecycle.Event.ON_DESTROY);
        analysisExecutor.shutdown();
        super.onDestroy();
    }

    private void toast(String s) {
        Log.w(TAG, s);
        runOnUiThread(() -> Toast.makeText(this, s, Toast.LENGTH_SHORT).show());
    }
}
