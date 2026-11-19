package app.zichuan.assistant;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Bundle;
import android.text.InputType;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.inputmethod.InputMethodManager;
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
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

/** 子川助手的 Android WebView 壳。认证 URL 由操作者从 dsh web 启动输出粘贴。 */
public class MainActivity extends Activity {

    private static final String PREFS = "zichuan";
    private static final String KEY_URL = "url";
    private static final int BG = Color.rgb(12, 18, 22);
    private static final int PANEL = Color.rgb(20, 29, 34);
    private static final int TEXT = Color.rgb(237, 243, 245);
    private static final int MUTED = Color.rgb(160, 176, 183);
    private static final int ACCENT = Color.rgb(55, 210, 187);

    private FrameLayout root;
    private WebView webView;
    private LinearLayout setupPanel;
    private TextView titleView;
    private TextView messageView;
    private EditText urlInput;
    private TextView configButton;
    private String currentUrl = "";

    @SuppressLint("SetJavaScriptEnabled")
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        root = new FrameLayout(this);
        root.setBackgroundColor(BG);
        webView = new WebView(this);
        root.addView(webView, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setDatabaseEnabled(true);
        settings.setAllowFileAccess(false);
        settings.setLoadWithOverviewMode(true);
        settings.setUseWideViewPort(true);
        settings.setSupportZoom(false);
        settings.setMediaPlaybackRequiresUserGesture(false);
        settings.setTextZoom(100);
        CookieManager.getInstance().setAcceptCookie(true);
        CookieManager.getInstance().setAcceptThirdPartyCookies(webView, true);

        webView.setWebViewClient(new Client(this));
        webView.setWebChromeClient(new WebChromeClient());
        webView.setOnLongClickListener(v -> {
            showSetup("连接设置", "粘贴 dsh web 打印的完整地址。仅填端口地址会触发认证提示。", currentUrl);
            return true;
        });

        configButton = new TextView(this);
        configButton.setText("连接设置");
        configButton.setTextColor(TEXT);
        configButton.setTextSize(12f);
        configButton.setGravity(Gravity.CENTER);
        configButton.setPadding(dp(14), 0, dp(14), 0);
        configButton.setBackground(rounded(PANEL, dp(18)));
        configButton.setElevation(dp(4));
        configButton.setOnClickListener(v -> showSetup(
                "连接设置", "粘贴 dsh web 打印的完整地址；通常包含 ?token=…", currentUrl));
        FrameLayout.LayoutParams configLp = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, dp(40), Gravity.TOP | Gravity.END);
        configLp.setMargins(0, dp(12), dp(12), 0);
        root.addView(configButton, configLp);
        configButton.setVisibility(View.GONE);

        buildSetupPanel();
        setContentView(root);

        currentUrl = getPreferences().getString(KEY_URL, "").trim();
        if (currentUrl.isEmpty()) {
            showSetup("连接子川助手", "先粘贴 dsh web 启动时打印的完整 URL。它通常包含 ?token=…；不要只填 http://127.0.0.1:3080/。", "");
        } else {
            load(currentUrl);
        }
    }

    private SharedPreferences getPreferences() {
        return getSharedPreferences(PREFS, MODE_PRIVATE);
    }

    private void buildSetupPanel() {
        setupPanel = new LinearLayout(this);
        setupPanel.setOrientation(LinearLayout.VERTICAL);
        setupPanel.setGravity(Gravity.CENTER_VERTICAL);
        setupPanel.setPadding(dp(24), dp(28), dp(24), dp(28));
        setupPanel.setBackgroundColor(BG);

        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        LinearLayout content = new LinearLayout(this);
        content.setOrientation(LinearLayout.VERTICAL);
        content.setPadding(0, dp(8), 0, dp(8));
        scroll.addView(content, new ScrollView.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        setupPanel.addView(scroll, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));

        TextView brand = new TextView(this);
        brand.setText("子川助手");
        brand.setTextColor(ACCENT);
        brand.setTextSize(14f);
        brand.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        content.addView(brand);

        titleView = new TextView(this);
        titleView.setTextColor(TEXT);
        titleView.setTextSize(25f);
        titleView.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        LinearLayout.LayoutParams titleLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        titleLp.topMargin = dp(14);
        content.addView(titleView, titleLp);

        messageView = new TextView(this);
        messageView.setTextColor(MUTED);
        messageView.setTextSize(14f);
        messageView.setLineSpacing(dp(3), 1f);
        LinearLayout.LayoutParams messageLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        messageLp.topMargin = dp(10);
        content.addView(messageView, messageLp);

        TextView label = new TextView(this);
        label.setText("DSH Web 完整地址");
        label.setTextColor(TEXT);
        label.setTextSize(13f);
        label.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        LinearLayout.LayoutParams labelLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        labelLp.topMargin = dp(28);
        content.addView(label, labelLp);

        urlInput = new EditText(this);
        urlInput.setSingleLine(true);
        urlInput.setTextSize(13f);
        urlInput.setTextColor(TEXT);
        urlInput.setHintTextColor(Color.rgb(113, 130, 138));
        urlInput.setHint("http://127.0.0.1:3080/?token=…");
        urlInput.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        urlInput.setSelectAllOnFocus(false);
        urlInput.setPadding(dp(14), 0, dp(14), 0);
        urlInput.setBackground(rounded(PANEL, dp(12)));
        LinearLayout.LayoutParams inputLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(54));
        inputLp.topMargin = dp(10);
        content.addView(urlInput, inputLp);

        Button pasteButton = makeButton("从剪贴板粘贴");
        LinearLayout.LayoutParams pasteLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(46));
        pasteLp.topMargin = dp(10);
        content.addView(pasteButton, pasteLp);
        pasteButton.setOnClickListener(v -> pasteUrl());

        Button connectButton = makeButton("保存并连接");
        connectButton.setTextColor(Color.rgb(8, 27, 27));
        connectButton.setBackground(rounded(ACCENT, dp(12)));
        connectButton.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        LinearLayout.LayoutParams connectLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(52));
        connectLp.topMargin = dp(12);
        content.addView(connectButton, connectLp);
        connectButton.setOnClickListener(v -> connectFromInput());

        TextView instructions = new TextView(this);
        instructions.setText("怎么拿地址\n在 DSH-Go 里打开「设置 → 本机引擎 → 日志」，复制 dsh web: 后面的完整 URL（含 ?token=…）；也可以从运行 dsh web 的终端复制。回到这里点粘贴并连接。链接只保存在本机。\n\n认证链接失效后，重新复制一条新的完整 URL 即可。连接成功后，右上角「连接设置」可随时更换。");
        instructions.setTextColor(MUTED);
        instructions.setTextSize(12f);
        instructions.setLineSpacing(dp(3), 1f);
        LinearLayout.LayoutParams instructionLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        instructionLp.topMargin = dp(22);
        content.addView(instructions, instructionLp);

        setupPanel.setVisibility(View.GONE);
        root.addView(setupPanel, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
    }

    private Button makeButton(String text) {
        Button button = new Button(this);
        button.setText(text);
        button.setTextSize(14f);
        button.setTextColor(TEXT);
        button.setAllCaps(false);
        button.setBackground(rounded(PANEL, dp(12)));
        return button;
    }

    private GradientDrawable rounded(int color, int radius) {
        GradientDrawable drawable = new GradientDrawable();
        drawable.setColor(color);
        drawable.setCornerRadius(radius);
        return drawable;
    }

    private int dp(float value) {
        return (int) (value * getResources().getDisplayMetrics().density + 0.5f);
    }

    private void pasteUrl() {
        ClipboardManager clipboard = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
        if (clipboard != null && clipboard.hasPrimaryClip()) {
            ClipData clip = clipboard.getPrimaryClip();
            if (clip != null && clip.getItemCount() > 0) {
                CharSequence text = clip.getItemAt(0).coerceToText(this);
                if (text != null) {
                    urlInput.setText(text.toString().trim());
                    urlInput.setSelection(urlInput.length());
                    return;
                }
            }
        }
        Toast.makeText(this, "剪贴板没有可粘贴的地址", Toast.LENGTH_SHORT).show();
    }

    private void connectFromInput() {
        String url = urlInput.getText().toString().trim();
        Uri parsed = Uri.parse(url);
        if (!(url.startsWith("http://") || url.startsWith("https://")) || parsed.getHost() == null) {
            Toast.makeText(this, "请粘贴完整的 http(s) URL", Toast.LENGTH_LONG).show();
            return;
        }
        currentUrl = url;
        getPreferences().edit().putString(KEY_URL, currentUrl).apply();
        View focused = getCurrentFocus();
        if (focused != null) {
            ((InputMethodManager) getSystemService(Context.INPUT_METHOD_SERVICE))
                    .hideSoftInputFromWindow(focused.getWindowToken(), 0);
            focused.clearFocus();
        }
        load(currentUrl);
    }

    private void load(String url) {
        currentUrl = url;
        configButton.setVisibility(View.GONE);
        showSetup("正在连接…", "正在检查 DSH Web 地址。认证链接只保存在此设备，不会写入日志。", url);
        webView.setVisibility(View.VISIBLE);
        webView.loadUrl(url);
    }

    private void showSetup(String title, String message, String url) {
        titleView.setText(title);
        messageView.setText(message);
        if (urlInput != null && !urlInput.hasFocus()) {
            urlInput.setText(url == null ? "" : url);
        }
        setupPanel.setVisibility(View.VISIBLE);
        setupPanel.bringToFront();
        configButton.setVisibility(View.GONE);
        webView.setVisibility(View.GONE);
    }

    private void showConnected() {
        setupPanel.setVisibility(View.GONE);
        webView.setVisibility(View.VISIBLE);
        configButton.setVisibility(View.VISIBLE);
    }

    private void showAuthenticationError() {
        showSetup(
                "需要认证链接",
                "DSH Web 收到了不带认证信息的地址。请在 DSH-Go「设置 → 本机引擎 → 日志」中复制 dsh web: 后面的完整 URL（通常带 ?token=…），再点「从剪贴板粘贴」和「保存并连接」。仅填 127.0.0.1:3080 不够。",
                currentUrl);
    }

    private void showNetworkError(String detail) {
        showSetup(
                "本机引擎没有响应",
                "检查 DSH Web 是否正在运行、端口是否正确。若服务正在运行，请粘贴启动时打印的完整认证 URL。\n\n错误：" + detail,
                currentUrl);
    }

    @Override
    public void onBackPressed() {
        if (setupPanel != null && setupPanel.getVisibility() == View.VISIBLE) {
            super.onBackPressed();
        } else if (webView != null && webView.canGoBack()) {
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

    /** DSH 返回 401 文本页时转成本机连接说明，不把认证提示留在空白 WebView。 */
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
            view.evaluateJavascript(
                    "Boolean(document.body && /dsh web authentication required|reopen the url printed by dsh web/i.test(document.body.innerText))",
                    result -> {
                        if ("true".equals(result)) {
                            host.showAuthenticationError();
                        } else {
                            host.showConnected();
                        }
                    });
        }

        @Override
        public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
            if (request.isForMainFrame()) {
                host.showNetworkError(String.valueOf(error.getDescription()));
            }
        }
    }
}
