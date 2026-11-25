package com.lvhao.netsync;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.util.AttributeSet;
import android.view.View;

/** 扫码取景框：四周压暗，中间留一个方框，四角画描边。 */
public class ScanOverlay extends View {

    private final Paint dim = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint corner = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Path path = new Path();

    public ScanOverlay(Context c, AttributeSet a) {
        super(c, a);
        dim.setColor(Color.parseColor("#66000000"));
        corner.setColor(Color.WHITE);
        corner.setStyle(Paint.Style.STROKE);
        corner.setStrokeWidth(dp(2.5f));
        corner.setStrokeCap(Paint.Cap.ROUND);
    }

    private float dp(float v) {
        return v * getResources().getDisplayMetrics().density;
    }

    @Override
    protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        int w = getWidth(), h = getHeight();
        float side = Math.min(w, h) * 0.66f;
        float cx = w / 2f;
        float cy = h * 0.44f;
        RectF hole = new RectF(cx - side / 2, cy - side / 2, cx + side / 2, cy + side / 2);

        path.reset();
        path.setFillType(Path.FillType.EVEN_ODD);
        path.addRect(0, 0, w, h, Path.Direction.CW);
        path.addRoundRect(hole, dp(18), dp(18), Path.Direction.CW);
        canvas.drawPath(path, dim);

        // 四角描边
        float arm = side * 0.22f;
        float r = dp(18);
        canvas.drawArc(new RectF(hole.left, hole.top, hole.left + r * 2, hole.top + r * 2),
                180, 90, false, corner);
        canvas.drawArc(new RectF(hole.right - r * 2, hole.top, hole.right, hole.top + r * 2),
                270, 90, false, corner);
        canvas.drawArc(new RectF(hole.left, hole.bottom - r * 2, hole.left + r * 2, hole.bottom),
                90, 90, false, corner);
        canvas.drawArc(new RectF(hole.right - r * 2, hole.bottom - r * 2, hole.right, hole.bottom),
                0, 90, false, corner);
        canvas.drawLine(hole.left + r, hole.top, hole.left + r + arm, hole.top, corner);
        canvas.drawLine(hole.right - r, hole.bottom, hole.right - r - arm, hole.bottom, corner);
    }
}
