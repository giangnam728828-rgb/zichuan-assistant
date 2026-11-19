package app.zichuan.assistant;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.os.Bundle;
import android.text.InputType;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.webkit.CookieManager;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

/**
 * 子川助手：把本机运行的 DeepSeek Harness Web UI 装进一个原生壳。
 *
 * 引擎仍在 proot 里跑（dsh web，默认 127.0.0.1:3080，本套件的 profile 在 3081），
 * 这个壳只负责全屏呈现、长按改地址、断连重试和返回键回退。
 */
public class MainActivity extends Activity {

    private static final String PREFS = "zichuan";
    private static final String KEY_URL = "url";
    private static final String DEFAULT_URL = "http://127.0.0.1:3080/";

    private WebView webView;
    private FrameLayout root;
    private LinearLayout errorBox;
    private TextView errorText;
    private String currentUrl;

    @SuppressLint("SetJavaScriptEnabled")
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        root = new FrameLayout(this);
        webView = new WebView(this);
        root.addView(webView, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setDatabaseEnabled(true);
        settings.setAllowFileAccess(true);
        settings.setLoadWithOverviewMode(true);
        settings.setUseWideViewPort(true);
        settings.setSupportZoom(false);
        settings.setMediaPlaybackRequiresUserGesture(false);
        settings.setTextZoom(100);
        CookieManager.getInstance().setAcceptCookie(true);
        CookieManager.getInstance().setAcceptThirdPartyCookies(webView, true);

        webView.setWebViewClient(new Client(this));
        webView.setWebChromeClient(new WebChromeClient());

        // 长按任意空白处改地址（本机端口可能不是 3080）
        webView.setOnLongClickListener(v -> {
            showUrlDialog();
            return true;
        });

        setContentView(root);

        currentUrl = getPreferences().getString(KEY_URL, DEFAULT_URL);
        load(currentUrl);
    }

    private SharedPreferences getPreferences() {
        return getSharedPreferences(PREFS, MODE_PRIVATE);
    }

    private void load(String url) {
        currentUrl = url;
        hideError();
        webView.loadUrl(url);
    }

    private void retry(String url) {
        currentUrl = url;
        getPreferences().edit().putString(KEY_URL, url).apply();
        hideError();
        // 加个随机查询串，绕开 WebView 的失败缓存
        webView.loadUrl(url + (url.contains("?") ? "&" : "?") + "zr=" + System.currentTimeMillis());
    }

    private void showUrlDialog() {
        EditText input = new EditText(this);
        input.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        input.setText(currentUrl);
        input.setSelection(input.getText().length());

        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        int pad = (int) (16 * getResources().getDisplayMetrics().density);
        box.setPadding(pad, pad, pad, 0);
        TextView hint = new TextView(this);
        hint.setText("引擎地址（dsh web 的输出，带 ?token= 最稳）");
        hint.setTextSize(12f);
        box.addView(hint);
        box.addView(input);

        new AlertDialog.Builder(this)
                .setTitle("子川助手")
                .setView(box)
                .setPositiveButton("打开", (d, w) -> retry(input.getText().toString().trim()))
                .setNeutralButton("3081", (d, w) -> retry("http://127.0.0.1:3081/"))
                .setNegativeButton("取消", null)
                .show();
    }

    private void showError(String detail) {
        if (errorBox == null) {
            errorBox = new LinearLayout(this);
            errorBox.setOrientation(LinearLayout.VERTICAL);
            errorBox.setGravity(Gravity.CENTER);
            errorBox.setBackgroundColor(Color.parseColor("#10161A"));
            int pad = (int) (24 * getResources().getDisplayMetrics().density);
            errorBox.setPadding(pad, pad, pad, pad);

            TextView title = new TextView(this);
            title.setText("连不上本机引擎");
            title.setTextColor(Color.parseColor("#E9EEF2"));
            title.setTextSize(18f);
            errorBox.addView(title);

            errorText = new TextView(this);
            errorText.setTextColor(Color.parseColor("#93A1AC"));
            errorText.setTextSize(12f);
            errorText.setPadding(0, pad / 2, 0, pad / 2);
            errorBox.addView(errorText);

            TextView tip = new TextView(this);
            tip.setText("先在电脑/手机环境里启动：\nbash scripts/zstart.sh\n再把带 token 的地址粘进来（长按屏幕可改）。");
            tip.setTextColor(Color.parseColor("#3AD6C0"));
            tip.setTextSize(12f);
            errorBox.addView(tip);

            Button retryButton = new Button(this);
            retryButton.setText("重试");
            retryButton.setOnClickListener(v -> retry(currentUrl));
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            lp.topMargin = pad;
            errorBox.addView(retryButton, lp);

            root.addView(errorBox, new FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        }
        errorText.setText(detail + "\n" + currentUrl);
        errorBox.setVisibility(View.VISIBLE);
        webView.setVisibility(View.GONE);
    }

    private void hideError() {
        if (errorBox != null) errorBox.setVisibility(View.GONE);
        webView.setVisibility(View.VISIBLE);
    }

    @Override
    public void onBackPressed() {
        if (webView.canGoBack()) {
            webView.goBack();
        } else {
            super.onBackPressed();
        }
    }

    @Override
    protected void onDestroy() {
        if (webView != null) {
            root.removeView(webView);
            webView.destroy();
        }
        super.onDestroy();
    }

    /** WebView 客户端：静态内部类，避免匿名内部类在 d8 上触发的编译器内部错误。 */
    private static final class Client extends WebViewClient {
        private final MainActivity host;

        Client(MainActivity host) {
            this.host = host;
        }

        @Override
        public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
            return false;
        }

        @Override
        public void onPageFinished(WebView view, String url) {
            host.hideError();
        }

        @Override
        public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
            if (request.isForMainFrame()) {
                host.showError(String.valueOf(error.getDescription()));
            }
        }
    }
}
