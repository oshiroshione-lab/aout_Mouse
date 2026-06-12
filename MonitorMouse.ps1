#requires -Version 5
<#
.SYNOPSIS
  ウィンドウ切り替え時に、フォーカスされたウィンドウが乗っているモニターの中心へ
  マウスカーソルを自動移動する常駐デーモン。

.DESCRIPTION
  SetWinEventHook (EVENT_SYSTEM_FOREGROUND) で最前面ウィンドウの変化を検知し、
  そのウィンドウのモニターと現在カーソルが居るモニターが異なる場合のみ、
  切り替え先モニターの中心へ SetCursorPos でカーソルを移動する。

  Alt+Tab / Ctrl+Tab(別ウィンドウへ) / クリック等、切り替え方法を問わず動作する。
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

namespace MonitorMouseDaemon {
  public static class Hook {
    delegate void WinEventDelegate(IntPtr hWinEventHook, uint eventType, IntPtr hwnd,
        int idObject, int idChild, uint dwEventThread, uint dwmsEventTime);

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

    [DllImport("user32.dll")]
    static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint dwFlags);
    [DllImport("user32.dll")]
    static extern IntPtr MonitorFromPoint(POINT pt, uint dwFlags);
    [DllImport("user32.dll")]
    static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO lpmi);
    [DllImport("user32.dll")]
    static extern bool GetCursorPos(out POINT lpPoint);
    [DllImport("user32.dll")]
    static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")]
    static extern int GetMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax);
    [DllImport("user32.dll")]
    static extern bool TranslateMessage(ref MSG lpMsg);
    [DllImport("user32.dll")]
    static extern IntPtr DispatchMessage(ref MSG lpMsg);

    [DllImport("user32.dll")]
    static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")]
    static extern bool SetProcessDPIAware();

    const uint EVENT_SYSTEM_FOREGROUND = 0x0003;
    const uint WINEVENT_OUTOFCONTEXT = 0x0000;
    const uint MONITOR_DEFAULTTONEAREST = 0x00000002;
    static readonly IntPtr DPI_PER_MONITOR_V2 = new IntPtr(-4);

    static WinEventDelegate _proc;     // GC で回収されないよう保持
    static IntPtr _hook = IntPtr.Zero;
    static IntPtr _lastHwnd = IntPtr.Zero;

    static void SetDpiAwareness() {
      try { if (SetProcessDpiAwarenessContext(DPI_PER_MONITOR_V2)) return; } catch {}
      try { SetProcessDPIAware(); } catch {}
    }

    static void OnForeground(IntPtr hWinEventHook, uint eventType, IntPtr hwnd,
        int idObject, int idChild, uint dwEventThread, uint dwmsEventTime) {
      if (hwnd == IntPtr.Zero) return;
      if (idObject != 0 || idChild != 0) return; // OBJID_WINDOW / CHILDID_SELF のみ
      if (hwnd == _lastHwnd) return;             // 同一ウィンドウへの重複イベントは無視
      _lastHwnd = hwnd;

      IntPtr targetMon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
      if (targetMon == IntPtr.Zero) return;

      POINT cur;
      if (!GetCursorPos(out cur)) return;
      IntPtr curMon = MonitorFromPoint(cur, MONITOR_DEFAULTTONEAREST);

      if (targetMon == curMon) return; // 既に同じモニターに居る場合は動かさない

      MONITORINFO mi = new MONITORINFO();
      mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
      if (!GetMonitorInfo(targetMon, ref mi)) return;

      int cx = (mi.rcMonitor.Left + mi.rcMonitor.Right) / 2;
      int cy = (mi.rcMonitor.Top + mi.rcMonitor.Bottom) / 2;
      SetCursorPos(cx, cy);
    }

    public static void Run() {
      SetDpiAwareness();
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
