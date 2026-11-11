// ClaudeSwitch — launches Claude Desktop with a profile of your choice.
// The first profile is always the default one: the existing Claude profile with the
// current login. Every other profile has a name and its own directory (--user-data-dir)
// and is managed from the settings dialog; profiles live in the registry under
// HKCU\Software\ClaudeSwitch\Profiles (a legacy profiles.json is migrated on first run).
// Without arguments the picker window opens; with a profile name it launches directly.
// The path to claude.exe changes with every Claude update, so it is resolved on each
// launch from the AppModel package repository (HKCU).
//
// Copyright (C) 2026 Oizopower. Licensed under the GNU GPL v3 or later; see LICENSE.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

class Profile
{
    public string Name;
    public string Path;   // empty = the default Claude profile
}

// The picker window. It can only be resized sideways: the top and bottom borders do not
// drag, the corners act as the side next to them, and while dragging the size snaps to
// whatever SnapClientSize returns (whole button columns, height following the rows).
class PickerForm : Form
{
    const int WM_NCHITTEST = 0x0084, WM_SIZING = 0x0214;
    const int HTLEFT = 10, HTRIGHT = 11, HTTOP = 12, HTTOPLEFT = 13, HTTOPRIGHT = 14,
              HTBOTTOM = 15, HTBOTTOMLEFT = 16, HTBOTTOMRIGHT = 17, HTBORDER = 18;
    const int WMSZ_LEFT = 1, WMSZ_TOPLEFT = 4, WMSZ_BOTTOMLEFT = 7;

    [StructLayout(LayoutKind.Sequential)]
    struct RECT { public int Left, Top, Right, Bottom; }

    // Maps a proposed client width to the client size the window should get.
    public Func<int, Size> SnapClientSize;

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_SIZING && SnapClientSize != null)
        {
            RECT r = (RECT)Marshal.PtrToStructure(m.LParam, typeof(RECT));
            Size chrome = Size - ClientSize;
            Size client = SnapClientSize(r.Right - r.Left - chrome.Width);
            int width = client.Width + chrome.Width;
            int edge = m.WParam.ToInt32();
            if (edge == WMSZ_LEFT || edge == WMSZ_TOPLEFT || edge == WMSZ_BOTTOMLEFT)
                r.Left = r.Right - width;   // keep the opposite edge where it is
            else
                r.Right = r.Left + width;
            r.Bottom = r.Top + client.Height + chrome.Height;
            Marshal.StructureToPtr(r, m.LParam, false);
            m.Result = (IntPtr)1;
            return;
        }

        base.WndProc(ref m);

        if (m.Msg == WM_NCHITTEST)
        {
            switch (m.Result.ToInt32())
            {
                case HTTOP:
                case HTBOTTOM: m.Result = (IntPtr)HTBORDER; break;
                case HTTOPLEFT:
                case HTBOTTOMLEFT: m.Result = (IntPtr)HTLEFT; break;
                case HTTOPRIGHT:
                case HTBOTTOMRIGHT: m.Result = (IntPtr)HTRIGHT; break;
            }
        }
    }
}

static class ClaudeSwitch
{
    const string PackagesKey = @"Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages";
    const string ProfilesKey = @"Software\ClaudeSwitch\Profiles";

    static readonly Color ColBg = Color.FromArgb(38, 38, 36);
    static readonly Color ColText = Color.FromArgb(245, 244, 239);
    static readonly Color ColDim = Color.FromArgb(140, 140, 135);
    static readonly Color ColOrange = Color.FromArgb(217, 119, 87);
    static readonly Color ColSlate = Color.FromArgb(58, 58, 56);

    static string BaseDir
    {
        get { return System.IO.Path.GetDirectoryName(Application.ExecutablePath); }
    }

    static string ConfigPath
    {
        get { return System.IO.Path.Combine(BaseDir, "profiles.json"); }
    }

    // ---------- profile storage (registry) ----------

    static List<Profile> LoadProfiles()
    {
        List<Profile> list = ReadRegistry();
        if (list == null) list = MigrateFromJson();
        if (list == null) list = SeedProfiles();
        list[0].Path = "";  // the first profile is always the default one
        SaveProfiles(list);
        return list;
    }

    static List<Profile> ReadRegistry()
    {
        using (RegistryKey key = Registry.CurrentUser.OpenSubKey(ProfilesKey))
        {
            if (key == null) return null;
            SortedDictionary<int, Profile> entries = new SortedDictionary<int, Profile>();
            foreach (string subName in key.GetSubKeyNames())
            {
                int index;
                if (!int.TryParse(subName, out index)) continue;
                using (RegistryKey sub = key.OpenSubKey(subName))
                {
                    if (sub == null) continue;
                    string name = sub.GetValue("Name") as string;
                    if (string.IsNullOrEmpty(name)) continue;
                    string path = (sub.GetValue("Path") as string) ?? "";
                    entries[index] = new Profile { Name = name, Path = path };
                }
            }
            if (entries.Count == 0) return null;
            return new List<Profile>(entries.Values);
        }
    }

    static void SaveProfiles(List<Profile> profiles)
    {
        Registry.CurrentUser.DeleteSubKeyTree(ProfilesKey, false);
        using (RegistryKey key = Registry.CurrentUser.CreateSubKey(ProfilesKey))
        {
            for (int i = 0; i < profiles.Count; i++)
            {
                using (RegistryKey sub = key.CreateSubKey(i.ToString()))
                {
                    sub.SetValue("Name", profiles[i].Name);
                    sub.SetValue("Path", profiles[i].Path ?? "");
                }
            }
        }
    }

    // One-time migration from the former profiles.json next to the executable.
    static List<Profile> MigrateFromJson()
    {
        try
        {
            if (!File.Exists(ConfigPath)) return null;
            JavaScriptSerializer ser = new JavaScriptSerializer();
            List<Profile> list = ser.Deserialize<List<Profile>>(File.ReadAllText(ConfigPath, Encoding.UTF8));
            if (list == null || list.Count == 0) return null;
            File.Delete(ConfigPath);
            return list;
        }
        catch { return null; }
    }

    static List<Profile> SeedProfiles()
    {
        List<Profile> list = new List<Profile>();
        list.Add(new Profile { Name = "Work", Path = "" });
        list.Add(new Profile { Name = "Personal", Path = System.IO.Path.Combine(BaseDir, "profiles\\personal") });
        return list;
    }

    // For name comparison and directory names: lower case, accents stripped.
    static string Normalize(string s)
    {
        string formD = s.Normalize(NormalizationForm.FormD);
        StringBuilder sb = new StringBuilder();
        foreach (char c in formD)
            if (CharUnicodeInfo.GetUnicodeCategory(c) != UnicodeCategory.NonSpacingMark)
                sb.Append(c);
        return sb.ToString().Normalize(NormalizationForm.FormC).ToLowerInvariant();
    }

    // Paths may contain environment variables (%USERPROFILE%\...). They are stored as
    // typed so a profile stays valid on another machine, and expanded on use.
    // A trailing separator is dropped: it would escape the closing quote of the
    // --user-data-dir argument on the command line.
    static string ExpandPath(string path)
    {
        if (string.IsNullOrEmpty(path)) return "";
        string expanded = Environment.ExpandEnvironmentVariables(path).Trim();
        return expanded.TrimEnd('\\', '/');
    }

    static string SuggestPath(string name)
    {
        StringBuilder sb = new StringBuilder();
        foreach (char c in Normalize(name))
            sb.Append(char.IsLetterOrDigit(c) ? c : '-');
        return System.IO.Path.Combine(BaseDir, System.IO.Path.Combine("profiles", sb.ToString()));
    }

    // ---------- launching Claude ----------

    static bool FindClaudePackage(out string fullName, out string rootFolder)
    {
        fullName = null;
        rootFolder = null;
        Version bestVersion = null;
        using (RegistryKey key = Registry.CurrentUser.OpenSubKey(PackagesKey))
        {
            if (key == null) return false;
            foreach (string name in key.GetSubKeyNames())
            {
                if (!name.StartsWith("Claude_", StringComparison.OrdinalIgnoreCase)) continue;
                string[] parts = name.Split('_');
                Version version;
                if (parts.Length < 2 || !Version.TryParse(parts[1], out version)) continue;
                using (RegistryKey sub = key.OpenSubKey(name))
                {
                    if (sub == null) continue;
                    string root = sub.GetValue("PackageRootFolder") as string;
                    if (root == null) continue;
                    if (bestVersion == null || version > bestVersion)
                    {
                        bestVersion = version;
                        fullName = name;
                        rootFolder = root;
                    }
                }
            }
        }
        return fullName != null;
    }

    static void StartProfile(Profile profile)
    {
        string fullName, rootFolder;
        if (!FindClaudePackage(out fullName, out rootFolder))
            throw new Exception("Claude Desktop was not found. Is the app still installed?");

        if (string.IsNullOrEmpty(profile.Path))
        {
            // Default profile: launch through the app identity, same as the normal Claude icon.
            int sep = fullName.IndexOf("__", StringComparison.Ordinal);
            if (sep < 0)
                throw new Exception("Unexpected package name: " + fullName);
            string family = "Claude_" + fullName.Substring(sep + 2);
            Process.Start("explorer.exe", "shell:AppsFolder\\" + family + "!Claude");
        }
        else
        {
            string exe = System.IO.Path.Combine(rootFolder, System.IO.Path.Combine("app", "claude.exe"));
            if (!File.Exists(exe))
                throw new Exception("claude.exe was not found in " + rootFolder);
            string dir = ExpandPath(profile.Path);
            Directory.CreateDirectory(dir);
            Process.Start(exe, "--user-data-dir=\"" + dir + "\"");
        }
    }

    // ---------- Start menu ----------

    static object ComGet(object obj, string name)
    {
        return obj.GetType().InvokeMember(name, BindingFlags.GetProperty, null, obj, null);
    }

    static object ComCall(object obj, string name, params object[] callArgs)
    {
        return obj.GetType().InvokeMember(name, BindingFlags.InvokeMethod, null, obj, callArgs);
    }

    static void ComSet(object obj, string name, object value)
    {
        obj.GetType().InvokeMember(name, BindingFlags.SetProperty, null, obj, new object[] { value });
    }

    static void EnsureStartMenuShortcut()
    {
        string lnkPath = System.IO.Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "Microsoft\\Windows\\Start Menu\\Programs\\ClaudeSwitch.lnk");
        object ws = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell"));
        object lnk = ComCall(ws, "CreateShortcut", lnkPath);
        ComSet(lnk, "TargetPath", Application.ExecutablePath);
        ComSet(lnk, "WorkingDirectory", BaseDir);
        ComSet(lnk, "IconLocation", Application.ExecutablePath + ",0");
        ComSet(lnk, "Description", "Launch Claude Desktop with a profile of your choice");
        ComCall(lnk, "Save");
    }

    // Tries the shell's "Pin to Start" verb. Windows normally blocks this for regular
    // programs (E_ACCESSDENIED), in which case this returns false.
    static bool TryPinToStart()
    {
        try
        {
            object shell = Activator.CreateInstance(Type.GetTypeFromProgID("Shell.Application"));
            object folder = ComCall(shell, "NameSpace", "shell:AppsFolder");
            object items = ComCall(folder, "Items");
            int count = (int)ComGet(items, "Count");
            object app = null;
            for (int i = 0; i < count; i++)
            {
                object item = ComCall(items, "Item", i);
                if ((string)ComGet(item, "Name") == "ClaudeSwitch") { app = item; break; }
            }
            if (app == null) return false;
            object verbs = ComCall(app, "Verbs");
            int verbCount = (int)ComGet(verbs, "Count");
            for (int i = 0; i < verbCount; i++)
            {
                object verb = ComCall(verbs, "Item", i);
                string name = ((string)ComGet(verb, "Name")).Replace("&", "");
                // Match both English and Dutch shells, but never the taskbar or unpin verbs.
                bool isStartPin =
                    name.IndexOf("start", StringComparison.OrdinalIgnoreCase) >= 0 &&
                    (name.IndexOf("pin", StringComparison.OrdinalIgnoreCase) >= 0 ||
                     name.IndexOf("vastmaken", StringComparison.OrdinalIgnoreCase) >= 0) &&
                    name.IndexOf("taskbar", StringComparison.OrdinalIgnoreCase) < 0 &&
                    name.IndexOf("taakbalk", StringComparison.OrdinalIgnoreCase) < 0 &&
                    name.IndexOf("unpin", StringComparison.OrdinalIgnoreCase) < 0 &&
                    name.IndexOf("losmaken", StringComparison.OrdinalIgnoreCase) < 0;
                if (isStartPin)
                {
                    ComCall(verb, "DoIt");
                    return true;
                }
            }
            return false;
        }
        catch
        {
            return false;
        }
    }

    // ---------- UI helpers ----------

    static void StyleButton(Button btn, Color back, Color fore, float fontSize)
    {
        btn.BackColor = back;
        btn.ForeColor = fore;
        btn.FlatStyle = FlatStyle.Flat;
        btn.FlatAppearance.BorderSize = 0;
        btn.Font = new Font("Segoe UI Semibold", fontSize);
    }

    static TextBox MakeTextBox(int x, int y, int w)
    {
        TextBox tb = new TextBox();
        tb.SetBounds(x, y, w, 24);
        tb.BackColor = ColSlate;
        tb.ForeColor = ColText;
        tb.BorderStyle = BorderStyle.FixedSingle;
        tb.Font = new Font("Segoe UI", 9f);
        return tb;
    }

    static Label MakeLabel(string text, int x, int y, int w)
    {
        Label lbl = new Label();
        lbl.Text = text;
        lbl.ForeColor = ColText;
        lbl.Font = new Font("Segoe UI", 9f);
        lbl.SetBounds(x, y, w, 18);
        return lbl;
    }

    // ---------- editing a single profile ----------

    // Small dialog for one profile (new or existing). Validates the name, rejects
    // duplicates and checks the path; returns true when the profile was changed.
    static bool EditProfile(Form owner, Profile profile, bool isDefault, List<Profile> all, int selfIndex)
    {
        Form dlg = new Form();
        dlg.Text = (selfIndex < 0) ? "New profile" : "Edit profile";
        dlg.ClientSize = new Size(408, 196);
        dlg.FormBorderStyle = FormBorderStyle.FixedSingle;
        dlg.MaximizeBox = false;
        dlg.MinimizeBox = false;
        dlg.StartPosition = FormStartPosition.CenterParent;
        dlg.BackColor = ColBg;
        dlg.ShowInTaskbar = false;
        try { dlg.Icon = owner.Icon; } catch { }

        dlg.Controls.Add(MakeLabel("Name:", 12, 14, 60));
        TextBox tbName = MakeTextBox(76, 11, 320);
        tbName.Text = profile.Name ?? "";
        dlg.Controls.Add(tbName);

        TextBox tbPath = null;
        if (isDefault)
        {
            Label note = MakeLabel("This is the default profile: your existing Claude login.\n" +
                "Only the name can be changed.", 12, 48, 384);
            note.ForeColor = ColDim;
            note.Height = 36;
            dlg.Controls.Add(note);
        }
        else
        {
            dlg.Controls.Add(MakeLabel("Folder:", 12, 48, 60));
            tbPath = MakeTextBox(76, 45, 282);
            tbPath.Text = profile.Path ?? "";
            dlg.Controls.Add(tbPath);

            Button btnBrowse = new Button();
            btnBrowse.Text = "…";
            btnBrowse.SetBounds(364, 44, 32, 26);
            StyleButton(btnBrowse, ColSlate, ColText, 9f);
            btnBrowse.Click += delegate
            {
                using (FolderBrowserDialog fb = new FolderBrowserDialog())
                {
                    fb.Description = "Choose the folder for this profile";
                    if (fb.ShowDialog(dlg) == DialogResult.OK) tbPath.Text = fb.SelectedPath;
                }
            };
            dlg.Controls.Add(btnBrowse);

            Label hint = MakeLabel("Leave empty for a folder under profiles\\. Variables like %USERPROFILE% work.", 76, 76, 320);
            hint.ForeColor = ColDim;
            hint.Font = new Font("Segoe UI", 8f);
            dlg.Controls.Add(hint);
        }

        Button btnOk = new Button();
        btnOk.Text = "OK";
        btnOk.SetBounds(188, 152, 100, 32);
        StyleButton(btnOk, ColOrange, ColBg, 9f);
        dlg.Controls.Add(btnOk);

        Button btnCancel = new Button();
        btnCancel.Text = "Cancel";
        btnCancel.SetBounds(296, 152, 100, 32);
        StyleButton(btnCancel, ColSlate, ColText, 9f);
        btnCancel.Click += delegate { dlg.DialogResult = DialogResult.Cancel; };
        dlg.Controls.Add(btnCancel);

        dlg.AcceptButton = btnOk;
        dlg.CancelButton = btnCancel;

        btnOk.Click += delegate
        {
            string name = tbName.Text.Trim();
            if (name.Length == 0)
            {
                MessageBox.Show(dlg, "Please give the profile a name.", "ClaudeSwitch",
                    MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }
            for (int j = 0; j < all.Count; j++)
            {
                if (j == selfIndex) continue;
                if (Normalize(all[j].Name) == Normalize(name))
                {
                    MessageBox.Show(dlg, "A profile named \"" + all[j].Name + "\" already exists.",
                        "ClaudeSwitch", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return;
                }
            }
            string newPath = "";
            if (!isDefault)
            {
                newPath = tbPath.Text.Trim();
                if (newPath.Length == 0)
                {
                    newPath = SuggestPath(name);
                }
                else
                {
                    bool valid;
                    string expanded = ExpandPath(newPath);
                    try { valid = System.IO.Path.IsPathRooted(expanded) && System.IO.Path.GetFullPath(expanded) != null; }
                    catch { valid = false; }
                    if (!valid)
                    {
                        MessageBox.Show(dlg, "That folder is not valid. Enter a full path, for example " +
                            "D:\\ClaudeProfiles\\name or %USERPROFILE%\\.claude-work.",
                            "ClaudeSwitch", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                        return;
                    }
                }
            }
            profile.Name = name;
            profile.Path = newPath;
            dlg.DialogResult = DialogResult.OK;
        };

        return dlg.ShowDialog(owner) == DialogResult.OK;
    }

    // ---------- settings ----------

    static void ShowSettings(Form owner, List<Profile> profiles)
    {
        Form dlg = new Form();
        dlg.Text = "ClaudeSwitch — settings";
        dlg.ClientSize = new Size(444, 240);
        dlg.FormBorderStyle = FormBorderStyle.FixedSingle;
        dlg.MaximizeBox = false;
        dlg.MinimizeBox = false;
        dlg.StartPosition = FormStartPosition.CenterParent;
        dlg.BackColor = ColBg;
        dlg.ShowInTaskbar = false;
        try { dlg.Icon = owner.Icon; } catch { }

        Label head = MakeLabel("The top profile uses your existing Claude login.", 12, 10, 420);
        head.ForeColor = ColDim;
        dlg.Controls.Add(head);

        ListBox lb = new ListBox();
        lb.SetBounds(12, 34, 320, 152);
        lb.BackColor = ColSlate;
        lb.ForeColor = ColText;
        lb.BorderStyle = BorderStyle.FixedSingle;
        lb.Font = new Font("Segoe UI", 9f);
        lb.IntegralHeight = false;
        dlg.Controls.Add(lb);

        Button btnNew = new Button();
        btnNew.Text = "New…";
        btnNew.SetBounds(340, 34, 92, 30);
        StyleButton(btnNew, ColOrange, ColBg, 9f);
        dlg.Controls.Add(btnNew);

        Button btnEdit = new Button();
        btnEdit.Text = "Edit…";
        btnEdit.SetBounds(340, 72, 92, 30);
        StyleButton(btnEdit, ColSlate, ColText, 9f);
        dlg.Controls.Add(btnEdit);

        Button btnDel = new Button();
        btnDel.Text = "Delete";
        btnDel.SetBounds(340, 110, 92, 30);
        StyleButton(btnDel, ColSlate, ColText, 9f);
        dlg.Controls.Add(btnDel);

        Button btnDefault = new Button();
        btnDefault.Text = "Make default";
        btnDefault.SetBounds(340, 156, 92, 30);
        StyleButton(btnDefault, ColSlate, ColText, 9f);
        dlg.Controls.Add(btnDefault);

        Button btnStart = new Button();
        btnStart.Text = "Add to Start menu";
        btnStart.SetBounds(12, 198, 150, 30);
        StyleButton(btnStart, ColSlate, ColText, 9f);
        dlg.Controls.Add(btnStart);

        Button btnClose = new Button();
        btnClose.Text = "Close";
        btnClose.SetBounds(332, 198, 100, 30);
        StyleButton(btnClose, ColSlate, ColText, 9f);
        btnClose.Click += delegate { dlg.Close(); };
        dlg.Controls.Add(btnClose);
        dlg.CancelButton = btnClose;

        Action refreshList = delegate
        {
            int sel = lb.SelectedIndex;
            lb.BeginUpdate();
            lb.Items.Clear();
            for (int i = 0; i < profiles.Count; i++)
            {
                string extra = (i == 0) ? "★ default — existing Claude login" : profiles[i].Path;
                lb.Items.Add(profiles[i].Name + "   —   " + extra);
            }
            lb.EndUpdate();
            if (sel >= 0 && sel < lb.Items.Count) lb.SelectedIndex = sel;
        };

        Action updateButtons = delegate
        {
            btnEdit.Enabled = lb.SelectedIndex >= 0;
            btnDel.Enabled = lb.SelectedIndex > 0;
            btnDefault.Enabled = lb.SelectedIndex > 0;
        };
        lb.SelectedIndexChanged += delegate { updateButtons(); };

        btnDefault.Click += delegate
        {
            int i = lb.SelectedIndex;
            if (i <= 0) return;
            Profile newDefault = profiles[i];
            Profile oldDefault = profiles[0];
            string oldDefaultPath = SuggestPath(oldDefault.Name);
            DialogResult answer = MessageBox.Show(dlg,
                "\"" + newDefault.Name + "\" will use the existing Claude login.\n\n" +
                "\"" + oldDefault.Name + "\" then gets its own profile folder:\n" +
                oldDefaultPath + "\n\n" +
                "You will sign in there once, the next time you use it. Continue?",
                "ClaudeSwitch", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            if (answer != DialogResult.Yes) return;
            oldDefault.Path = oldDefaultPath;
            newDefault.Path = "";
            profiles[0] = newDefault;
            profiles[i] = oldDefault;
            SaveProfiles(profiles);
            refreshList();
            lb.SelectedIndex = 0;
            updateButtons();
        };

        btnNew.Click += delegate
        {
            Profile p = new Profile { Name = "", Path = "" };
            if (EditProfile(dlg, p, false, profiles, -1))
            {
                profiles.Add(p);
                SaveProfiles(profiles);
                refreshList();
                lb.SelectedIndex = lb.Items.Count - 1;
            }
        };

        Action editSelected = delegate
        {
            int i = lb.SelectedIndex;
            if (i < 0) return;
            if (EditProfile(dlg, profiles[i], i == 0, profiles, i))
            {
                SaveProfiles(profiles);
                refreshList();
            }
        };
        btnEdit.Click += delegate { editSelected(); };
        lb.DoubleClick += delegate { editSelected(); };

        btnDel.Click += delegate
        {
            int i = lb.SelectedIndex;
            if (i <= 0) return;
            DialogResult answer = MessageBox.Show(dlg,
                "Remove the profile \"" + profiles[i].Name + "\" from the list?\n" +
                "(The profile folder itself stays on disk.)", "ClaudeSwitch",
                MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            if (answer != DialogResult.Yes) return;
            profiles.RemoveAt(i);
            SaveProfiles(profiles);
            refreshList();
            updateButtons();
        };

        btnStart.Click += delegate
        {
            try
            {
                EnsureStartMenuShortcut();
                if (TryPinToStart())
                {
                    MessageBox.Show(dlg, "ClaudeSwitch is in the Start menu and pinned.",
                        "ClaudeSwitch", MessageBoxButtons.OK, MessageBoxIcon.Information);
                }
                else
                {
                    MessageBox.Show(dlg,
                        "ClaudeSwitch is now in the Start menu (search for \"ClaudeSwitch\").\n\n" +
                        "Windows blocks apps from pinning themselves. The apps folder will open " +
                        "now: right-click ClaudeSwitch there and choose \"Pin to Start\".",
                        "ClaudeSwitch", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    Process.Start("explorer.exe", "shell:AppsFolder");
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show(dlg, ex.Message, "ClaudeSwitch",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        };

        refreshList();
        updateButtons();
        dlg.ShowDialog(owner);
    }

    // ---------- picker window ----------

    // Button grid of the picker. A grid of n columns is GridMargin + n * ColPitch wide.
    const int GridMargin = 20, GridTop = 50;
    const int ButtonW = 150, ButtonH = 70, ColPitch = 170, RowPitch = 80;
    const int DefaultColumns = 3;     // up to three profiles on one row, the fourth wraps
    const int MinWindowColumns = 2;   // never narrower than two columns: the question must fit
    const string SettingsKey = @"Software\ClaudeSwitch";

    // Number of columns the user chose by resizing the picker (DefaultColumns until then).
    static int LoadColumns()
    {
        using (RegistryKey key = Registry.CurrentUser.OpenSubKey(SettingsKey))
        {
            object value = (key == null) ? null : key.GetValue("Columns");
            return (value is int && (int)value > 0) ? (int)value : DefaultColumns;
        }
    }

    static void SaveColumns(int columns)
    {
        using (RegistryKey key = Registry.CurrentUser.CreateSubKey(SettingsKey))
            key.SetValue("Columns", columns, RegistryValueKind.DWord);
    }

    static Form BuildMainForm(List<Profile> profiles)
    {
        PickerForm form = new PickerForm();
        form.Text = "ClaudeSwitch";
        form.FormBorderStyle = FormBorderStyle.Sizable;
        form.SizeGripStyle = SizeGripStyle.Hide;
        form.MaximizeBox = false;
        form.MinimizeBox = false;
        form.StartPosition = FormStartPosition.CenterScreen;
        form.BackColor = ColBg;
        form.KeyPreview = true;
        form.KeyDown += delegate(object s, KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Escape) form.Close();
        };
        try { form.Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); }
        catch { }

        Label label = new Label();
        label.Text = "Which account do you want to start Claude with?";
        label.ForeColor = ColText;
        label.Font = new Font("Segoe UI", 10f);
        label.TextAlign = ContentAlignment.MiddleCenter;
        form.Controls.Add(label);

        Label footer = new Label();
        footer.ForeColor = ColDim;
        footer.Font = new Font("Segoe UI", 8f);
        footer.TextAlign = ContentAlignment.MiddleLeft;
        form.Controls.Add(footer);

        LinkLabel settings = new LinkLabel();
        settings.Text = "settings";
        settings.LinkColor = ColDim;
        settings.ActiveLinkColor = ColText;
        settings.LinkBehavior = LinkBehavior.HoverUnderline;
        settings.Font = new Font("Segoe UI", 8f);
        settings.TextAlign = ContentAlignment.MiddleRight;
        form.Controls.Add(settings);

        List<Button> buttons = new List<Button>();
        int preferred = LoadColumns();

        // Columns the window is wide: at least MinWindowColumns, at most one per profile,
        // and never wider than the screen it is on.
        Func<int, int> clampColumns = delegate(int columns)
        {
            int chromeWidth = form.Width - form.ClientSize.Width;
            int screenMax = (Screen.FromControl(form).WorkingArea.Width - chromeWidth - GridMargin) / ColPitch;
            int max = Math.Max(MinWindowColumns, Math.Min(profiles.Count, screenMax));
            return Math.Max(MinWindowColumns, Math.Min(columns, max));
        };

        Func<int, int> buttonsPerRow = delegate(int columns)
        {
            return Math.Max(1, Math.Min(columns, profiles.Count));
        };

        Func<int, Size> clientSizeFor = delegate(int columns)
        {
            int perRow = buttonsPerRow(columns);
            int rows = (profiles.Count + perRow - 1) / perRow;
            return new Size(GridMargin + columns * ColPitch, GridTop + rows * RowPitch + 28);
        };

        // While the user drags a side, the width snaps to the nearest whole column.
        form.SnapClientSize = delegate(int width)
        {
            int columns = (int)Math.Round((width - GridMargin) / (double)ColPitch);
            return clientSizeFor(clampColumns(columns));
        };

        Func<int> currentColumns = delegate
        {
            return clampColumns((form.ClientSize.Width - GridMargin) / ColPitch);
        };

        // Places the controls for the current width; the grid is centred, so a lone
        // button does not hug the left edge of the (two-column minimum) window.
        Action arrange = delegate
        {
            int width = form.ClientSize.Width;
            int perRow = buttonsPerRow(currentColumns());
            int rows = (buttons.Count + perRow - 1) / perRow;
            int left = (width - (perRow * ColPitch - (ColPitch - ButtonW))) / 2;
            for (int i = 0; i < buttons.Count; i++)
                buttons[i].SetBounds(left + (i % perRow) * ColPitch, GridTop + (i / perRow) * RowPitch, ButtonW, ButtonH);

            int footerY = GridTop + rows * RowPitch + 4;
            label.SetBounds(0, 12, width, 24);
            footer.SetBounds(GridMargin, footerY, width - 2 * GridMargin - 90, 18);
            settings.SetBounds(width - GridMargin - 90, footerY, 90, 18);
        };

        Action rebuild = delegate
        {
            form.SuspendLayout();
            foreach (Button old in buttons)
            {
                form.Controls.Remove(old);
                old.Dispose();
            }
            buttons.Clear();

            for (int i = 0; i < profiles.Count; i++)
            {
                Profile p = profiles[i];
                Button btn = new Button();
                btn.Text = p.Name;
                if (i == 0) StyleButton(btn, ColOrange, ColBg, 14f);
                else StyleButton(btn, ColSlate, ColText, 14f);
                btn.Click += delegate
                {
                    try
                    {
                        StartProfile(p);
                        form.Close();
                    }
                    catch (Exception ex)
                    {
                        MessageBox.Show(form, ex.Message, "ClaudeSwitch",
                            MessageBoxButtons.OK, MessageBoxIcon.Error);
                    }
                };
                buttons.Add(btn);
                form.Controls.Add(btn);
            }
            footer.Text = "★ " + profiles[0].Name + " = your Claude login";

            form.ClientSize = clientSizeFor(clampColumns(preferred));
            arrange();
            form.ResumeLayout();
        };

        settings.Click += delegate
        {
            ShowSettings(form, profiles);
            rebuild();
        };

        form.Resize += delegate { arrange(); };

        // Remember a width the user dragged to. Moving the window also ends here, so only
        // save when the column count actually changed.
        form.ResizeEnd += delegate
        {
            int columns = currentColumns();
            if (columns != clampColumns(preferred))
            {
                preferred = columns;
                try { SaveColumns(columns); } catch { }
            }
        };

        rebuild();
        return form;
    }

    [STAThread]
    static void Main(string[] args)
    {
        Application.EnableVisualStyles();
        List<Profile> profiles = LoadProfiles();

        // Hidden: create the Start menu shortcut without a window (exit code 0 = pinned
        // as well, 2 = shortcut only). Same logic as the settings button.
        if (args.Length > 0 && args[0] == "/startmenu")
        {
            try
            {
                EnsureStartMenuShortcut();
                Environment.Exit(TryPinToStart() ? 0 : 2);
            }
            catch (Exception ex)
            {
                MessageBox.Show(ex.Message, "ClaudeSwitch", MessageBoxButtons.OK, MessageBoxIcon.Error);
                Environment.Exit(1);
            }
            return;
        }

        if (args.Length > 0)
        {
            try
            {
                Profile match = null;
                string want = Normalize(args[0]);
                foreach (Profile p in profiles)
                    if (Normalize(p.Name) == want) { match = p; break; }
                if (match == null)
                {
                    List<string> names = new List<string>();
                    foreach (Profile p in profiles) names.Add(p.Name);
                    throw new Exception("Unknown profile: " + args[0] +
                        " (available: " + string.Join(", ", names.ToArray()) + ")");
                }
                StartProfile(match);
            }
            catch (Exception ex)
            {
                MessageBox.Show(ex.Message, "ClaudeSwitch", MessageBoxButtons.OK, MessageBoxIcon.Error);
                Environment.Exit(1);
            }
            return;
        }

        Application.Run(BuildMainForm(profiles));
    }
}
