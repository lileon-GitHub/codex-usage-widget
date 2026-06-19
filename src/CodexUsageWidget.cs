using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace CodexUsageWidget
{
    internal static class Program
    {
        [STAThread]
        private static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new UsageForm());
        }
    }

    internal sealed class UsageSnapshot
    {
        public bool Found;
        public string Plan = "未知";
        public long TodayTokens;
        public long ThreadInputTokens;
        public long ThreadCachedTokens;
        public long ThreadOutputTokens;
        public long ThreadReasoningTokens;
        public long ThreadTotalTokens;
        public long LastInputTokens;
        public long LastCachedTokens;
        public long LastOutputTokens;
        public long LastReasoningTokens;
        public long LastTotalTokens;
        public double? PrimaryPercent;
        public double? SecondaryPercent;
        public long? PrimaryReset;
        public long? SecondaryReset;
        public bool PrimaryLocallyReset;
        public bool SecondaryLocallyReset;
        public DateTime? LatestEventTime;
    }

    internal sealed class UsageForm : Form
    {
        private readonly string codexHome;
        private readonly string settingsDir;
        private readonly string settingsPath;
        private readonly Timer refreshTimer;
        private readonly Label titleLabel;
        private readonly Label limitLabel;
        private readonly Label tokenLabel;
        private readonly Panel accentPanel;
        private ToolStripMenuItem startupItem;
        private string detailText = "等待首次刷新...";
        private Point? dragStart;

        public UsageForm()
        {
            codexHome = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");
            settingsDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "CodexUsageMeter");
            settingsPath = Path.Combine(settingsDir, "settings.json");

            Text = "Codex 用量显示";
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;
            StartPosition = FormStartPosition.Manual;
            Size = new Size(232, 58);
            BackColor = Color.FromArgb(17, 24, 39);
            ContextMenuStrip = BuildMenu();

            accentPanel = new Panel { Dock = DockStyle.Left, Width = 5, BackColor = Color.FromArgb(52, 211, 153), ContextMenuStrip = ContextMenuStrip };
            Controls.Add(accentPanel);

            titleLabel = NewLabel("Codex 剩余额度", new Point(15, 4), new Size(206, 14), 8f, FontStyle.Regular, Color.FromArgb(209, 213, 219));
            limitLabel = NewLabel("等待日志", new Point(14, 18), new Size(212, 20), 10f, FontStyle.Bold, Color.White);
            tokenLabel = NewLabel("等待 Codex 写入用量日志", new Point(15, 39), new Size(212, 14), 7.5f, FontStyle.Regular, Color.FromArgb(156, 163, 175));
            Controls.Add(titleLabel);
            Controls.Add(limitLabel);
            Controls.Add(tokenLabel);

            HookDrag(this);
            HookDrag(titleLabel);
            HookDrag(limitLabel);
            HookDrag(tokenLabel);

            Shown += delegate { ApplyRoundedRegion(); };
            Resize += delegate { ApplyRoundedRegion(); };
            Paint += PaintBorder;

            refreshTimer = new Timer { Interval = 30000 };
            refreshTimer.Tick += delegate { UpdateUsage(); };
            UpdateUsage();
            refreshTimer.Start();
        }

        private ContextMenuStrip BuildMenu()
        {
            var menu = new ContextMenuStrip();
            menu.Items.Add("查看详情", null, delegate { MessageBox.Show(detailText, "Codex 用量详情", MessageBoxButtons.OK, MessageBoxIcon.Information); });
            menu.Items.Add("-");
            menu.Items.Add("立即刷新", null, delegate { UpdateUsage(); });
            menu.Items.Add("打开 ChatGPT / Codex", null, delegate { OpenUrl("https://chatgpt.com/codex"); });
            menu.Items.Add("如何用 /status 校准", null, delegate
            {
                MessageBox.Show("在 Codex 输入框里输入 /status，可以查看上下文用量和 rate limits。\r\n\r\n如果你使用 CLI/TUI，也可以输入 /usage 查看账号 token 活动或使用 rate-limit reset。\r\n\r\n本工具读取本机 session 日志做估算，不是官方个人账号额度 API。", "Codex 用量校准", MessageBoxButtons.OK, MessageBoxIcon.Information);
            });
            menu.Items.Add("-");
            startupItem = new ToolStripMenuItem("开机启动");
            startupItem.CheckOnClick = true;
            startupItem.Checked = IsStartupEnabled();
            startupItem.CheckedChanged += delegate
            {
                SetStartupEnabled(startupItem.Checked);
                startupItem.Checked = IsStartupEnabled();
            };
            menu.Items.Add(startupItem);
            menu.Items.Add("-");
            menu.Items.Add("退出", null, delegate { refreshTimer.Stop(); Close(); Application.Exit(); });
            return menu;
        }

        private Label NewLabel(string text, Point location, Size size, float fontSize, FontStyle style, Color color)
        {
            return new Label
            {
                AutoSize = false,
                Location = location,
                Size = size,
                Text = text,
                TextAlign = ContentAlignment.MiddleLeft,
                Font = new Font("Microsoft YaHei UI", fontSize, style),
                ForeColor = color,
                BackColor = Color.Transparent,
                ContextMenuStrip = ContextMenuStrip
            };
        }

        private void HookDrag(Control control)
        {
            control.MouseDown += delegate(object sender, MouseEventArgs e) { if (e.Button == MouseButtons.Left) dragStart = e.Location; };
            control.MouseMove += delegate(object sender, MouseEventArgs e)
            {
                if (dragStart.HasValue && e.Button == MouseButtons.Left)
                {
                    Left += e.X - dragStart.Value.X;
                    Top += e.Y - dragStart.Value.Y;
                }
            };
            control.MouseUp += delegate { dragStart = null; SaveWindowLocation(); };
        }

        private void UpdateUsage()
        {
            bool running = IsCodexRunning();
            UsageSnapshot snapshot = ReadSnapshot();
            limitLabel.Text = GetDisplayText(snapshot);
            tokenLabel.Text = GetTokenText(snapshot);
            accentPanel.BackColor = GetAccentColor(snapshot);
            detailText = GetDetailText(snapshot, running);

            if (running)
            {
                if (!Visible)
                {
                    SetInitialLocation();
                    Show();
                }
            }
            else
            {
                Hide();
            }
        }

        private static bool IsCodexRunning()
        {
            try
            {
                return Process.GetProcesses().Any(p => p.ProcessName.Equals("Codex", StringComparison.OrdinalIgnoreCase) || p.ProcessName.StartsWith("codex", StringComparison.OrdinalIgnoreCase));
            }
            catch { return false; }
        }

        private UsageSnapshot ReadSnapshot()
        {
            var snapshot = new UsageSnapshot();
            string sessionsRoot = Path.Combine(codexHome, "sessions");
            if (!Directory.Exists(sessionsRoot)) return snapshot;

            DateTime today = DateTime.Today;
            FileInfo[] files;
            try
            {
                files = new DirectoryInfo(sessionsRoot).GetFiles("*.jsonl", SearchOption.AllDirectories).Where(f => f.LastWriteTime >= today.AddDays(-1)).OrderByDescending(f => f.LastWriteTime).ToArray();
            }
            catch { return snapshot; }

            TokenEvent latest = FindLatestTokenEvent(files);
            long todayTokens = SumTodayTokenEvents(files, today);

            if (latest == null) return snapshot;
            snapshot.Found = true;
            snapshot.Plan = string.IsNullOrWhiteSpace(latest.Plan) ? "未知" : latest.Plan;
            snapshot.TodayTokens = todayTokens;
            snapshot.ThreadInputTokens = latest.ThreadInputTokens;
            snapshot.ThreadCachedTokens = latest.ThreadCachedTokens;
            snapshot.ThreadOutputTokens = latest.ThreadOutputTokens;
            snapshot.ThreadReasoningTokens = latest.ThreadReasoningTokens;
            snapshot.ThreadTotalTokens = latest.ThreadTotalTokens;
            snapshot.LastInputTokens = latest.LastInputTokens;
            snapshot.LastCachedTokens = latest.LastCachedTokens;
            snapshot.LastOutputTokens = latest.LastOutputTokens;
            snapshot.LastReasoningTokens = latest.LastReasoningTokens;
            snapshot.LastTotalTokens = latest.LastTotalTokens;
            snapshot.PrimaryPercent = latest.PrimaryUsedPercent;
            snapshot.SecondaryPercent = latest.SecondaryUsedPercent;
            snapshot.PrimaryReset = latest.PrimaryReset;
            snapshot.SecondaryReset = latest.SecondaryReset;
            ApplyLocalResetInference(snapshot);
            snapshot.LatestEventTime = latest.Timestamp.HasValue ? latest.Timestamp.Value.LocalDateTime : (DateTime?)null;
            return snapshot;
        }

        private static void ApplyLocalResetInference(UsageSnapshot snapshot)
        {
            long now = DateTimeOffset.Now.ToUnixTimeSeconds();

            if (snapshot.PrimaryReset.HasValue && now >= snapshot.PrimaryReset.Value)
            {
                snapshot.PrimaryPercent = 0;
                snapshot.PrimaryLocallyReset = true;
            }

            if (snapshot.SecondaryReset.HasValue && now >= snapshot.SecondaryReset.Value)
            {
                snapshot.SecondaryPercent = 0;
                snapshot.SecondaryLocallyReset = true;
            }
        }

        private static TokenEvent FindLatestTokenEvent(FileInfo[] files)
        {
            foreach (FileInfo file in files)
            {
                string[] lines;
                try { lines = ReadAllLinesShared(file.FullName); } catch { continue; }

                for (int i = lines.Length - 1; i >= 0; i--)
                {
                    string line = lines[i];
                    if (line.IndexOf("\"token_count\"", StringComparison.Ordinal) < 0) continue;
                    TokenEvent parsed = TokenEvent.TryParse(line);
                    if (parsed != null) return parsed;
                }
            }

            return null;
        }

        private static long SumTodayTokenEvents(FileInfo[] files, DateTime today)
        {
            long todayTokens = 0;

            foreach (FileInfo file in files)
            {
                string[] lines;
                try { lines = ReadAllLinesShared(file.FullName); } catch { continue; }
                foreach (string line in lines)
                {
                    if (line.IndexOf("\"token_count\"", StringComparison.Ordinal) < 0) continue;
                    TokenEvent parsed = TokenEvent.TryParse(line);
                    if (parsed == null) continue;
                    if (parsed.Timestamp.HasValue && parsed.Timestamp.Value.LocalDateTime >= today) todayTokens += parsed.LastTotalTokens;
                }
            }

            return todayTokens;
        }

        private static string[] ReadAllLinesShared(string path)
        {
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            using (var reader = new StreamReader(stream, Encoding.UTF8, true))
            {
                string text = reader.ReadToEnd();
                return text.Split(new[] { "\r\n", "\n" }, StringSplitOptions.None);
            }
        }

        private string GetDisplayText(UsageSnapshot snapshot)
        {
            if (!snapshot.Found) return "等待日志";
            return string.Format(CultureInfo.CurrentCulture, "5小时 {0}   本周 {1}", FormatPercent(GetRemaining(snapshot.PrimaryPercent)), FormatPercent(GetRemaining(snapshot.SecondaryPercent)));
        }

        private string GetTokenText(UsageSnapshot snapshot)
        {
            if (!snapshot.Found) return "等待 Codex 写入用量日志";
            if (snapshot.PrimaryLocallyReset) return "5小时已重置 · 等待新窗口 token";
            return string.Format(CultureInfo.CurrentCulture, "入 {0}  ·  命中 {1}  ·  出 {2}", FormatToken(snapshot.ThreadInputTokens), FormatToken(snapshot.ThreadCachedTokens), FormatToken(snapshot.ThreadOutputTokens));
        }

        private string GetDetailText(UsageSnapshot snapshot, bool running)
        {
            if (!running) return "Codex 未运行，窗口已隐藏";
            if (!snapshot.Found) return "Codex 正在运行，但还没有读到 token_count 日志";
            string primaryUsed = snapshot.PrimaryPercent.HasValue ? snapshot.PrimaryPercent.Value.ToString("N0", CultureInfo.CurrentCulture) + "%" : "未知";
            string secondaryUsed = snapshot.SecondaryPercent.HasValue ? snapshot.SecondaryPercent.Value.ToString("N0", CultureInfo.CurrentCulture) + "%" : "未知";
            string primaryReset = snapshot.PrimaryLocallyReset ? "已到重置时间，等待 Codex 同步" : FormatReset(snapshot.PrimaryReset);
            string secondaryReset = snapshot.SecondaryLocallyReset ? "已到重置时间，等待 Codex 同步" : FormatReset(snapshot.SecondaryReset);
            string updated = snapshot.LatestEventTime.HasValue ? snapshot.LatestEventTime.Value.ToString("MM-dd HH:mm:ss", CultureInfo.CurrentCulture) : "未知";
            return string.Format(CultureInfo.CurrentCulture,
                "Codex 用量估算 ({0})\r\n5小时剩余: {1}，已用: {2}，重置: {3}\r\n本周剩余: {4}，已用: {5}，重置: {6}\r\n\r\n当前线程累计: {7} tokens\r\n输入: {8}，缓存命中: {9}\r\n输出: {10}，推理输出: {11}\r\n\r\n最近一次: {12} tokens\r\n输入: {13}，缓存命中: {14}\r\n输出: {15}，推理输出: {16}\r\n\r\n今日估算: {17} tokens（本地日志估算，仅供参考）\r\n更新: {18}",
                snapshot.Plan, FormatPercent(GetRemaining(snapshot.PrimaryPercent)), primaryUsed, primaryReset,
                FormatPercent(GetRemaining(snapshot.SecondaryPercent)), secondaryUsed, secondaryReset,
                FormatToken(snapshot.ThreadTotalTokens), FormatToken(snapshot.ThreadInputTokens), FormatToken(snapshot.ThreadCachedTokens), FormatToken(snapshot.ThreadOutputTokens), FormatToken(snapshot.ThreadReasoningTokens),
                FormatToken(snapshot.LastTotalTokens), FormatToken(snapshot.LastInputTokens), FormatToken(snapshot.LastCachedTokens), FormatToken(snapshot.LastOutputTokens), FormatToken(snapshot.LastReasoningTokens),
                FormatToken(snapshot.TodayTokens), updated);
        }

        private static double? GetRemaining(double? used) { return used.HasValue ? Math.Max(0, Math.Min(100, 100 - used.Value)) : (double?)null; }
        private static string FormatPercent(double? value) { return value.HasValue ? value.Value.ToString("N0", CultureInfo.CurrentCulture) + "%" : "--"; }
        private static string FormatToken(long tokens)
        {
            if (tokens >= 1000000) return (tokens / 1000000.0).ToString("N2", CultureInfo.CurrentCulture) + "M";
            if (tokens >= 1000) return (tokens / 1000.0).ToString("N1", CultureInfo.CurrentCulture) + "K";
            return tokens.ToString(CultureInfo.CurrentCulture);
        }

        private static string FormatReset(long? unixSeconds)
        {
            if (!unixSeconds.HasValue) return "未知";
            try { return DateTimeOffset.FromUnixTimeSeconds(unixSeconds.Value).LocalDateTime.ToString("MM-dd HH:mm", CultureInfo.CurrentCulture); } catch { return "未知"; }
        }

        private static Color GetAccentColor(UsageSnapshot snapshot)
        {
            double? primaryRemaining = GetRemaining(snapshot.PrimaryPercent);
            if (!primaryRemaining.HasValue) return Color.FromArgb(107, 114, 128);
            if (primaryRemaining.Value <= 15) return Color.FromArgb(248, 113, 113);
            if (primaryRemaining.Value <= 40) return Color.FromArgb(251, 191, 36);
            return Color.FromArgb(52, 211, 153);
        }

        private void SetInitialLocation()
        {
            Point? saved = LoadWindowLocation();
            if (saved.HasValue) { Location = saved.Value; return; }
            Rectangle workArea = Screen.PrimaryScreen.WorkingArea;
            Location = new Point(workArea.Right - Width - 12, workArea.Bottom - Height - 10);
        }

        private Point? LoadWindowLocation()
        {
            try
            {
                if (!File.Exists(settingsPath)) return null;
                string text = File.ReadAllText(settingsPath, Encoding.UTF8);
                Match x = Regex.Match(text, "\"x\"\\s*:\\s*(-?\\d+)");
                Match y = Regex.Match(text, "\"y\"\\s*:\\s*(-?\\d+)");
                if (x.Success && y.Success) return new Point(int.Parse(x.Groups[1].Value, CultureInfo.InvariantCulture), int.Parse(y.Groups[1].Value, CultureInfo.InvariantCulture));
            }
            catch { }
            return null;
        }

        private void SaveWindowLocation()
        {
            try
            {
                Directory.CreateDirectory(settingsDir);
                File.WriteAllText(settingsPath, string.Format(CultureInfo.InvariantCulture, "{{\"x\":{0},\"y\":{1}}}", Left, Top), Encoding.UTF8);
            }
            catch { }
        }

        private void ApplyRoundedRegion()
        {
            using (GraphicsPath path = NewRoundedPath(Width, Height, 10)) Region = new Region(path);
        }

        private void PaintBorder(object sender, PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (GraphicsPath path = NewRoundedPath(Width, Height, 10))
            using (Pen pen = new Pen(Color.FromArgb(31, 41, 55), 1))
                e.Graphics.DrawPath(pen, path);
        }

        private static GraphicsPath NewRoundedPath(int width, int height, int radius)
        {
            int diameter = radius * 2;
            var rect = new Rectangle(0, 0, width - 1, height - 1);
            var path = new GraphicsPath();
            path.AddArc(rect.Left, rect.Top, diameter, diameter, 180, 90);
            path.AddArc(rect.Right - diameter, rect.Top, diameter, diameter, 270, 90);
            path.AddArc(rect.Right - diameter, rect.Bottom - diameter, diameter, diameter, 0, 90);
            path.AddArc(rect.Left, rect.Bottom - diameter, diameter, diameter, 90, 90);
            path.CloseFigure();
            return path;
        }

        private static void OpenUrl(string url)
        {
            try { Process.Start(url); } catch { MessageBox.Show("无法打开：" + url, "Codex 用量显示", MessageBoxButtons.OK, MessageBoxIcon.Warning); }
        }

        private static string StartupShortcutPath
        {
            get
            {
                string startup = Environment.GetFolderPath(Environment.SpecialFolder.Startup);
                return Path.Combine(startup, "Codex Usage Meter.lnk");
            }
        }

        private static bool IsStartupEnabled()
        {
            return File.Exists(StartupShortcutPath);
        }

        private void SetStartupEnabled(bool enabled)
        {
            try
            {
                string shortcutPath = StartupShortcutPath;
                if (!enabled)
                {
                    if (File.Exists(shortcutPath))
                        File.Delete(shortcutPath);
                    return;
                }

                string exePath = Application.ExecutablePath;
                Type shellType = Type.GetTypeFromProgID("WScript.Shell");
                if (shellType == null)
                    throw new InvalidOperationException("WScript.Shell 不可用");

                object shell = Activator.CreateInstance(shellType);
                object shortcut = shellType.InvokeMember("CreateShortcut", System.Reflection.BindingFlags.InvokeMethod, null, shell, new object[] { shortcutPath });
                Type shortcutType = shortcut.GetType();
                shortcutType.InvokeMember("TargetPath", System.Reflection.BindingFlags.SetProperty, null, shortcut, new object[] { exePath });
                shortcutType.InvokeMember("WorkingDirectory", System.Reflection.BindingFlags.SetProperty, null, shortcut, new object[] { Path.GetDirectoryName(exePath) });
                shortcutType.InvokeMember("Description", System.Reflection.BindingFlags.SetProperty, null, shortcut, new object[] { "Codex 用量显示" });
                shortcutType.InvokeMember("Save", System.Reflection.BindingFlags.InvokeMethod, null, shortcut, null);
            }
            catch (Exception ex)
            {
                MessageBox.Show("更新开机启动失败：\r\n" + ex.Message, "Codex 用量显示", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }
    }

    internal sealed class TokenEvent
    {
        public string TimestampRaw;
        public DateTimeOffset? Timestamp;
        public string Plan;
        public long ThreadInputTokens, ThreadCachedTokens, ThreadOutputTokens, ThreadReasoningTokens, ThreadTotalTokens;
        public long LastInputTokens, LastCachedTokens, LastOutputTokens, LastReasoningTokens, LastTotalTokens;
        public double? PrimaryUsedPercent, SecondaryUsedPercent;
        public long? PrimaryReset, SecondaryReset;

        public static TokenEvent TryParse(string line)
        {
            try
            {
                var serializer = new JavaScriptSerializer();
                var root = serializer.DeserializeObject(line) as Dictionary<string, object>;
                if (root == null || GetString(root, "type") != "event_msg")
                    return null;

                var payload = GetDict(root, "payload");
                if (payload == null || GetString(payload, "type") != "token_count")
                    return null;

                var info = GetDict(payload, "info");
                var rateLimits = GetDict(payload, "rate_limits");
                if (info == null || rateLimits == null)
                    return null;

                var total = GetDict(info, "total_token_usage");
                var last = GetDict(info, "last_token_usage");
                var primary = GetDict(rateLimits, "primary");
                var secondary = GetDict(rateLimits, "secondary");

                var item = new TokenEvent();
                item.TimestampRaw = GetString(root, "timestamp");
                DateTimeOffset parsedTime;
                if (!string.IsNullOrEmpty(item.TimestampRaw) && DateTimeOffset.TryParse(item.TimestampRaw, out parsedTime))
                    item.Timestamp = parsedTime;

                item.Plan = GetString(rateLimits, "plan_type");

                if (total != null)
                {
                    item.ThreadInputTokens = GetLong(total, "input_tokens");
                    item.ThreadCachedTokens = GetLong(total, "cached_input_tokens");
                    item.ThreadOutputTokens = GetLong(total, "output_tokens");
                    item.ThreadReasoningTokens = GetLong(total, "reasoning_output_tokens");
                    item.ThreadTotalTokens = GetLong(total, "total_tokens");
                }

                if (last != null)
                {
                    item.LastInputTokens = GetLong(last, "input_tokens");
                    item.LastCachedTokens = GetLong(last, "cached_input_tokens");
                    item.LastOutputTokens = GetLong(last, "output_tokens");
                    item.LastReasoningTokens = GetLong(last, "reasoning_output_tokens");
                    item.LastTotalTokens = GetLong(last, "total_tokens");
                }

                if (primary != null)
                {
                    item.PrimaryUsedPercent = GetDouble(primary, "used_percent");
                    item.PrimaryReset = GetNullableLong(primary, "resets_at");
                }

                if (secondary != null)
                {
                    item.SecondaryUsedPercent = GetDouble(secondary, "used_percent");
                    item.SecondaryReset = GetNullableLong(secondary, "resets_at");
                }

                return item;
            }
            catch
            {
                return null;
            }
        }

        private static Dictionary<string, object> GetDict(Dictionary<string, object> dict, string key)
        {
            object value;
            if (!dict.TryGetValue(key, out value))
                return null;
            return value as Dictionary<string, object>;
        }

        private static string GetString(Dictionary<string, object> dict, string key)
        {
            object value;
            if (!dict.TryGetValue(key, out value) || value == null)
                return "";
            return Convert.ToString(value, CultureInfo.InvariantCulture);
        }

        private static long GetLong(Dictionary<string, object> dict, string key)
        {
            long? value = GetNullableLong(dict, key);
            return value.HasValue ? value.Value : 0;
        }

        private static long? GetNullableLong(Dictionary<string, object> dict, string key)
        {
            object value;
            if (!dict.TryGetValue(key, out value) || value == null)
                return null;
            return Convert.ToInt64(value, CultureInfo.InvariantCulture);
        }

        private static double? GetDouble(Dictionary<string, object> dict, string key)
        {
            object value;
            if (!dict.TryGetValue(key, out value) || value == null)
                return null;
            return Convert.ToDouble(value, CultureInfo.InvariantCulture);
        }
    }
}
