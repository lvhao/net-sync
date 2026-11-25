package com.lvhao.netsync;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.os.Environment;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.io.File;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/** 在手机上逐级选择同步目录。 */
public class FolderPicker extends Activity {

    public static final String EXTRA_FOLDER_ID = "folderId";
    public static final String EXTRA_FOLDER_NAME = "folderName";
    public static final String EXTRA_START = "startPath";

    private File current;
    private File root;
    private LinearLayout list;
    private TextView pathView;
    private String folderId, folderName;

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        setContentView(R.layout.activity_pick);

        root = Environment.getExternalStorageDirectory();
        list = findViewById(R.id.entries);
        pathView = findViewById(R.id.path);

        folderId = getIntent().getStringExtra(EXTRA_FOLDER_ID);
        folderName = getIntent().getStringExtra(EXTRA_FOLDER_NAME);
        String start = getIntent().getStringExtra(EXTRA_START);

        findViewById(R.id.up).setOnClickListener(v -> {
            File parent = current.getParentFile();
            if (parent != null && parent.getAbsolutePath().startsWith(root.getAbsolutePath())) {
                current = parent;
                render();
            }
        });
        findViewById(R.id.here).setOnClickListener(v -> {
            Config cfg = Config.load(this);
            Config.Pair p = cfg.pair(folderId);
            if (p == null) {
                p = new Config.Pair();
                p.folderId = folderId;
                p.folderName = folderName;
                cfg.pairs.add(p);
            } else {
                p.folderName = folderName;
            }
            p.localDir = current.getAbsolutePath();
            cfg.save(this);
            setResult(RESULT_OK, new Intent());
            finish();
        });

        File suggested = new File(root, folderName == null ? "NetSync" : folderName);
        if (start != null && !start.isEmpty()) {
            current = new File(start);
        } else if (suggested.isDirectory()) {
            current = suggested;
        } else {
            current = root;
        }
        if (!current.isDirectory()) current = root;
        render();
    }

    private void render() {
        pathView.setText(current.getAbsolutePath());
        list.removeAllViews();
        File[] items = current.listFiles();
        List<File> dirs = new ArrayList<>();
        if (items != null) {
            Arrays.sort(items, (a, c) -> a.getName().compareToIgnoreCase(c.getName()));
            for (File f : items) {
                if (f.isDirectory() && !f.getName().startsWith(".")) dirs.add(f);
            }
        }
        for (int i = 0; i < dirs.size(); i++) {
            File dir = dirs.get(i);
            LinearLayout row = new LinearLayout(this);
            row.setOrientation(LinearLayout.HORIZONTAL);
            row.setGravity(android.view.Gravity.CENTER_VERTICAL);
            row.setPadding(dp(16), dp(14), dp(14), dp(14));
            row.setBackgroundResource(R.drawable.bg_card);
            LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT);
            params.bottomMargin = dp(8);
            row.setLayoutParams(params);

            ImageView icon = new ImageView(this);
            icon.setImageResource(R.drawable.ic_folder);
            icon.setPadding(dp(8), dp(8), dp(8), dp(8));
            icon.setBackgroundResource(R.drawable.bg_soft);
            row.addView(icon, new LinearLayout.LayoutParams(dp(36), dp(36)));

            TextView name = new TextView(this);
            name.setText(dir.getName());
            name.setTextSize(14);
            name.setTextColor(0xFF1D1D1F);
            LinearLayout.LayoutParams nameParams = new LinearLayout.LayoutParams(
                    0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f);
            nameParams.leftMargin = dp(12);
            row.addView(name, nameParams);

            ImageView chevron = new ImageView(this);
            chevron.setImageResource(R.drawable.ic_chevron);
            row.addView(chevron, new LinearLayout.LayoutParams(dp(16), dp(16)));

            row.setOnClickListener(v -> { current = dir; render(); });
            list.addView(row);
        }
        if (dirs.isEmpty()) {
            TextView empty = new TextView(this);
            empty.setText("（没有子目录，可直接用当前目录）");
            empty.setTextSize(12);
            empty.setTextColor(0xFF86868B);
            empty.setPadding(dp(8), dp(20), dp(8), dp(20));
            list.addView(empty);
        }
    }
}
