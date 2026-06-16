#requires -Version 5
<#
.SYNOPSIS
  ウィンドウ切り替え時に、フォーカスされたウィンドウが乗っているモニターの中心へ
  マウスカーソルを自動移動する常駐デーモン。

.DESCRIPTION
  SetWinEventHook (EVENT_SYSTEM_FOREGROUND) で最前面ウィンドウの変化を検知する。
  1回の切り替えでは Alt+Tab / Task View 等の切替UIを含む複数のフォアグラウンド
  イベントが連続発火するため、即時移動はせず「一定時間(settle)新しいイベントが
  来なくなってから」最終的な前面ウィンドウのモニター中心へ一度だけ移動する。
  これによりカーソルが切替UI(プライマリ側)へ引き戻されるバウンスを防ぐ。

  - 切替UI(Task View / Alt+Tab オーバーレイ)のウィンドウクラスは無視する。
  - マウスボタンでフォーカスした場合(クリック)は移動しない。
  - カーソルが既に切替先ウィンドウと同じモニター上にある場合は移動しない。
    これにより「隠れているインジケーターを表示します」やトレイのミニアプリ
    (monitorian 等)のフライアウトを開いてもカーソルが飛ばない。
  - スリープ/画面ロックからの復帰直後は一定時間カーソル移動を抑制する。
    復帰時に発生するディスプレイ再構成・前面ウィンドウ復元のフォアグラウンド
    イベントでカーソルが勝手に中央へ飛ぶのを防ぐ。
  - 外部モニター接続時(画面が2台以上)のみ動作する。単一画面のときは
    何もしない(実質オフ)。接続/切断は切り替えごとに毎回判定するため、
    デーモンを再起動せずとも即座に反映される。

  ※ Ctrl+Tab が「同一ウィンドウ内のタブ切り替え」の場合は最前面ウィンドウが
    変わらないため発火しない（仕様）。

.PARAMETER Validate
  C# のコンパイル可否のみ確認して終了する（デーモンは起動しない）。
#>
param(
  [switch]$Validate
)

$ErrorActionPreference = 'Stop'

$source = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace MonitorMouseDaemon {
  public static class Hook {
    delegate void WinEventDelegate(IntPtr hWinEventHook, uint eventType, IntPtr hwnd,
        int idObject, int idChild, uint dwEventThread, uint dwmsEventTime);
    delegate IntPtr WndProcDelegate(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern IntPtr SetWinEventHook(uint eventMin, uint eventMax, IntPtr hmodWinEventProc,
        WinEventDelegate lpfnWinEventProc, uint idProcess, uint idThread, uint dwFlags);
    [DllImport("user32.dll")]
    static extern bool UnhookWinEvent(IntPtr hWinEventHook);

    [StructLayout(LayoutKind.Sequential)]
    struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)]
    struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    struct MONITORINFO {
      public int cbSize;
      public RECT rcMonitor;
      public RECT rcWork;
      public uint dwFlags;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct MSG {
      public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam;
      public uint time; public POINT pt;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct WNDCLASS {
      public uint style;
      public IntPtr lpfnWndProc;
      public int cbClsExtra;
      public int cbWndExtra;
      public IntPtr hInstance;
      public IntPtr hIcon;
      public IntPtr hCursor;
      public IntPtr hbrBackground;
      [MarshalAs(UnmanagedType.LPWStr)] public string lpszMenuName;
      [MarshalAs(UnmanagedType.LPWStr)] public string lpszClassName;
    }

    delegate bool MonitorEnumDelegate(IntPtr hMonitor, IntPtr hdcMonitor, ref RECT lprcMonitor, IntPtr dwData);

    [DllImport("user32.dll")]
    static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint dwFlags);
    [DllImport("user32.dll")]
    static extern IntPtr MonitorFromPoint(POINT pt, uint dwFlags);
    [DllImport("user32.dll")]
    static extern bool GetCursorPos(out POINT lpPoint);
    [DllImport("user32.dll")]
    static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO lpmi);
    [DllImport("user32.dll")]
    static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr lprcClip, MonitorEnumDelegate lpfnEnum, IntPtr dwData);
    [DllImport("user32.dll")]
    static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll")]
    static extern short GetAsyncKeyState(int vKey);

    [DllImport("user32.dll")]
    static extern int GetMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax);
    [DllImport("user32.dll")]
    static extern bool TranslateMessage(ref MSG lpMsg);
    [DllImport("user32.dll")]
    static extern IntPtr DispatchMessage(ref MSG lpMsg);
    [DllImport("user32.dll")]
    static extern UIntPtr SetTimer(IntPtr hWnd, UIntPtr nIDEvent, uint uElapse, IntPtr lpTimerFunc);
    [DllImport("user32.dll")]
    static extern bool KillTimer(IntPtr hWnd, UIntPtr uIDEvent);

    // 非表示ウィンドウ(電源/セッション通知の受信先・settle タイマーの宿主)
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern ushort RegisterClassW(ref WNDCLASS lpWndClass);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateWindowExW(uint dwExStyle, string lpClassName, string lpWindowName,
        uint dwStyle, int x, int y, int nWidth, int nHeight, IntPtr hWndParent, IntPtr hMenu,
        IntPtr hInstance, IntPtr lpParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr DefWindowProcW(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr GetModuleHandleW(string lpModuleName);
    [DllImport("wtsapi32.dll", SetLastError = true)]
    static extern bool WTSRegisterSessionNotification(IntPtr hWnd, uint dwFlags);
    [DllImport("wtsapi32.dll", SetLastError = true)]
    static extern bool WTSUnRegisterSessionNotification(IntPtr hWnd);
    [DllImport("user32.dll", SetLastError = true)]
    static extern IntPtr RegisterSuspendResumeNotification(IntPtr hRecipient, uint flags);

    [DllImport("user32.dll")]
    static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")]
    static extern bool SetProcessDPIAware();

    const uint EVENT_SYSTEM_FOREGROUND = 0x0003;
    const uint WINEVENT_OUTOFCONTEXT = 0x0000;
    const uint MONITOR_DEFAULTTONEAREST = 0x00000002;
    const uint WM_TIMER = 0x0113;
    const uint WM_WTSSESSION_CHANGE = 0x02B1;
    const uint WM_POWERBROADCAST = 0x0218;
    const uint SETTLE_MS = 120;        // 連続イベントが落ち着くまでの待機(ミリ秒)
    const int RESUME_GRACE_MS = 3000;  // 復帰直後にカーソル移動を抑制する時間(ミリ秒)
    const int VK_LBUTTON = 0x01;
    const int VK_RBUTTON = 0x02;
    const int VK_MBUTTON = 0x04;

    // WTS セッション変化イベント
    const int WTS_SESSION_LOGON = 0x5;
    const int WTS_SESSION_LOGOFF = 0x6;
    const int WTS_SESSION_LOCK = 0x7;
    const int WTS_SESSION_UNLOCK = 0x8;
    const uint NOTIFY_FOR_THIS_SESSION = 0;
    // 電源(サスペンド/復帰)イベント
    const int PBT_APMSUSPEND = 0x0004;
    const int PBT_APMRESUMESUSPEND = 0x0007;
    const int PBT_APMRESUMEAUTOMATIC = 0x0012;
    const uint DEVICE_NOTIFY_WINDOW_HANDLE = 0x00000000;

    static readonly IntPtr DPI_PER_MONITOR_V2 = new IntPtr(-4);
    static readonly UIntPtr TIMER_ID = new UIntPtr(1);

    static WinEventDelegate _proc;         // GC で回収されないよう保持
    static WndProcDelegate _wndProc;       // 同上(ウィンドウプロシージャ)
    static MonitorEnumDelegate _countProc; // 同上(モニター列挙コールバック)
    static IntPtr _hook = IntPtr.Zero;
    static IntPtr _hwnd = IntPtr.Zero;
    static bool _armed = false;            // settle タイマー設定中か
    static bool _clickDuringBurst = false;
    static bool _locked = false;           // 画面ロック/サスペンド中か
    static int _suppressUntil = 0;         // この TickCount まで移動を抑制(復帰直後など)
    static int _monitorCount = 0;          // CountMonitors 用の一時カウンタ

    static void SetDpiAwareness() {
      try { if (SetProcessDpiAwarenessContext(DPI_PER_MONITOR_V2)) return; } catch {}
      try { SetProcessDPIAware(); } catch {}
    }

    static bool AnyMouseButtonDown() {
      return (GetAsyncKeyState(VK_LBUTTON) & 0x8000) != 0
          || (GetAsyncKeyState(VK_RBUTTON) & 0x8000) != 0
          || (GetAsyncKeyState(VK_MBUTTON) & 0x8000) != 0;
    }

    // 復帰直後の抑制期間中か(TickCount のラップアラウンドに耐える符号付き差分比較)
    static bool Suppressed() {
      return (Environment.TickCount - _suppressUntil) < 0;
    }

    static void Suppress(int ms) {
      _suppressUntil = Environment.TickCount + ms;
    }

    static void CancelTimer() {
      if (_armed) { KillTimer(_hwnd, TIMER_ID); _armed = false; }
    }

    // 接続中のモニター台数を数える。EnumDisplayMonitors は同期呼び出しのため
    // この関数の実行中にコールバックが完結する(メッセージループ専用スレッドから呼ぶ)。
    static int CountMonitors() {
      _monitorCount = 0;
      if (_countProc == null) _countProc = new MonitorEnumDelegate(CountMonitorProc);
      EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, _countProc, IntPtr.Zero);
      return _monitorCount;
    }

    static bool CountMonitorProc(IntPtr hMonitor, IntPtr hdcMonitor, ref RECT lprcMonitor, IntPtr dwData) {
      _monitorCount++;
      return true; // 列挙を継続
    }

    // Alt+Tab / Task View 等の切替UIウィンドウは無視する
    static bool IsSwitcherWindow(IntPtr hwnd) {
      var sb = new StringBuilder(128);
      GetClassName(hwnd, sb, sb.Capacity);
      string c = sb.ToString();
      return c == "MultitaskingViewFrame"        // Task View
          || c == "XamlExplorerHostIslandWindow" // Win11 Alt+Tab
          || c == "ForegroundStaging"
          || c == "TaskSwitcherWnd"
          || c == "TaskSwitcherOverlayWnd";
    }

    // フォアグラウンド変化イベント: 即時には動かさず settle タイマーを張り直すだけ
    static void OnForeground(IntPtr hWinEventHook, uint eventType, IntPtr hwnd,
        int idObject, int idChild, uint dwEventThread, uint dwmsEventTime) {
      if (hwnd == IntPtr.Zero) return;
      if (idObject != 0 || idChild != 0) return; // OBJID_WINDOW / CHILDID_SELF のみ
      if (_locked || Suppressed()) return;        // ロック中・復帰直後は何もしない

      if (AnyMouseButtonDown()) _clickDuringBurst = true; // クリック由来のフォーカスを記録

      CancelTimer();
      if (SetTimer(_hwnd, TIMER_ID, SETTLE_MS, IntPtr.Zero) != UIntPtr.Zero) _armed = true;
    }

    // settle 経過後に一度だけ呼ばれ、最終的な前面ウィンドウのモニター中心へ移動
    static void OnSettle() {
      bool click = _clickDuringBurst;
      _clickDuringBurst = false; // 次のバーストに向けてリセット

      if (_locked || Suppressed()) return;             // ロック中・復帰直後は移動しない
      if (CountMonitors() < 2) return;                 // 外部モニター未接続(単一画面)では動作しない

      IntPtr hwnd = GetForegroundWindow();
      if (hwnd == IntPtr.Zero) return;
      if (IsSwitcherWindow(hwnd)) return;              // 切替UIが前面なら何もしない(後で本ウィンドウが来る)
      if (click || AnyMouseButtonDown()) return;       // クリック操作では動かさない

      IntPtr mon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
      if (mon == IntPtr.Zero) return;

      // カーソルが既に切替先ウィンドウと同じモニター上にいるなら動かさない。
      // トレイのフライアウト(隠れているインジケーター / monitorian 等)は
      // クリックしたモニター上に開くため、これで余計な移動を防ぐ。
      POINT cp;
      if (GetCursorPos(out cp) && MonitorFromPoint(cp, MONITOR_DEFAULTTONEAREST) == mon) return;

      MONITORINFO mi = new MONITORINFO();
      mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
      if (!GetMonitorInfo(mon, ref mi)) return;

      int cx = (mi.rcMonitor.Left + mi.rcMonitor.Right) / 2;
      int cy = (mi.rcMonitor.Top + mi.rcMonitor.Bottom) / 2;
      SetCursorPos(cx, cy);
    }

    // 非表示ウィンドウのプロシージャ: タイマー満了・電源・セッション変化を処理
    static IntPtr WndProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam) {
      if (msg == WM_TIMER) {
        CancelTimer();
        OnSettle();
        return IntPtr.Zero;
      }
      if (msg == WM_WTSSESSION_CHANGE) {
        int e = wParam.ToInt32();
        if (e == WTS_SESSION_LOCK) {
          _locked = true; CancelTimer();
        } else if (e == WTS_SESSION_UNLOCK || e == WTS_SESSION_LOGON) {
          _locked = false; Suppress(RESUME_GRACE_MS); CancelTimer();
        } else if (e == WTS_SESSION_LOGOFF) {
          _locked = true; CancelTimer();
        }
        return IntPtr.Zero;
      }
      if (msg == WM_POWERBROADCAST) {
        int ev = wParam.ToInt32();
        if (ev == PBT_APMSUSPEND) {
          Suppress(RESUME_GRACE_MS); CancelTimer();
        } else if (ev == PBT_APMRESUMEAUTOMATIC || ev == PBT_APMRESUMESUSPEND) {
          Suppress(RESUME_GRACE_MS); CancelTimer();
        }
        return new IntPtr(1); // TRUE
      }
      return DefWindowProcW(hWnd, msg, wParam, lParam);
    }

    public static void Run() {
      SetDpiAwareness();

      // 通知受信用の非表示ウィンドウを作成(トップレベル・非表示のまま)
      _wndProc = new WndProcDelegate(WndProc);
      WNDCLASS wc = new WNDCLASS();
      wc.lpfnWndProc = Marshal.GetFunctionPointerForDelegate(_wndProc);
      wc.hInstance = GetModuleHandleW(null);
      wc.lpszClassName = "MonitorMouseHiddenWnd";
      if (RegisterClassW(ref wc) == 0)
        throw new Exception("RegisterClassW failed: " + Marshal.GetLastWin32Error());
      _hwnd = CreateWindowExW(0, wc.lpszClassName, "MonitorMouse", 0, 0, 0, 0, 0,
          IntPtr.Zero, IntPtr.Zero, wc.hInstance, IntPtr.Zero);
      if (_hwnd == IntPtr.Zero)
        throw new Exception("CreateWindowExW failed: " + Marshal.GetLastWin32Error());

      // ロック/アンロック・サスペンド/復帰の通知を受け取る(失敗は致命的ではない)
      WTSRegisterSessionNotification(_hwnd, NOTIFY_FOR_THIS_SESSION);
      RegisterSuspendResumeNotification(_hwnd, DEVICE_NOTIFY_WINDOW_HANDLE);

      _proc = new WinEventDelegate(OnForeground);
      _hook = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND,
          IntPtr.Zero, _proc, 0, 0, WINEVENT_OUTOFCONTEXT);
      if (_hook == IntPtr.Zero) throw new Exception("SetWinEventHook failed");

      MSG msg;
      int ret;
      while ((ret = GetMessage(out msg, IntPtr.Zero, 0, 0)) != 0) {
        if (ret == -1) break;
        TranslateMessage(ref msg);
        DispatchMessage(ref msg);
      }
      UnhookWinEvent(_hook);
      WTSUnRegisterSessionNotification(_hwnd);
    }
  }
}
'@

Add-Type -TypeDefinition $source -Language CSharp

if ($Validate) {
  Write-Host 'Compiled OK'
  return
}

# メッセージループに入りブロックする（常駐）。停止はプロセス終了で行う。
[MonitorMouseDaemon.Hook]::Run()