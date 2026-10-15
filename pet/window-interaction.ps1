# Keep window activation separate from account queries and artwork so it can be
# tested with an isolated WinForms fixture, without starting the desktop pet.
Add-Type -AssemblyName System.Windows.Forms

if (-not ('BalancePetForm' -as [type])) {
  $petWindowCode = @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class BalancePetForm : Form {
    const int GWL_EXSTYLE = -20;
    const int WS_EX_NOACTIVATE = 0x08000000;
    const int WS_EX_TOPMOST = 0x00000008;
    const int WM_MOUSEACTIVATE = 0x0021;
    const int MA_NOACTIVATE = 3;
    const uint SWP_NOSIZE = 0x0001;
    const uint SWP_NOMOVE = 0x0002;
    const uint SWP_NOZORDER = 0x0004;
    const uint SWP_NOACTIVATE = 0x0010;
    const uint SWP_FRAMECHANGED = 0x0020;
    const uint SWP_NOOWNERZORDER = 0x0200;
    bool noActivate = true;
    bool topMost;

    // GWL_EXSTYLE stores a 32-bit style value, including on 64-bit Windows.
    [DllImport("user32.dll", SetLastError = true)]
    static extern int GetWindowLong(IntPtr hwnd, int index);
    [DllImport("user32.dll", SetLastError = true)]
    static extern int SetWindowLong(IntPtr hwnd, int index, int value);
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);

    // Form.CreateHandle reapplies its own TopMost property with an activating
    // SetWindowPos call. Keep that base property false and apply the desired
    // native topmost style ourselves, including across handle recreation.
    public new bool TopMost {
        get { return topMost; }
        set {
            if (topMost == value) return;
            if (IsHandleCreated) {
                if (!SetWindowPos(Handle, new IntPtr(value ? -1 : -2), 0, 0, 0, 0,
                    SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER))
                    throw new InvalidOperationException("SetWindowPos failed: " + Marshal.GetLastWin32Error());
            }
            topMost = value;
        }
    }

    public bool NoActivate {
        get { return noActivate; }
        set {
            if (noActivate == value) return;
            if (IsHandleCreated) {
                int style = GetWindowLong(Handle, GWL_EXSTYLE);
                int next = value ? style | WS_EX_NOACTIVATE : style & ~WS_EX_NOACTIVATE;
                int previous = SetWindowLong(Handle, GWL_EXSTYLE, next);
                int error = Marshal.GetLastWin32Error();
                if (previous == 0 && error != 0) throw new InvalidOperationException("SetWindowLong failed: " + error);
                // Do not recreate the handle: that would discard its layered
                // bitmap and interrupt mouse capture while the pet is dragged.
                SetWindowPos(Handle, IntPtr.Zero, 0, 0, 0, 0,
                    SWP_NOSIZE | SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE |
                    SWP_FRAMECHANGED | SWP_NOOWNERZORDER);
            }
            noActivate = value;
        }
    }

    protected override bool ShowWithoutActivation {
        get { return noActivate; }
    }

    protected override CreateParams CreateParams {
        get {
            CreateParams parameters = base.CreateParams;
            if (noActivate) parameters.ExStyle |= WS_EX_NOACTIVATE;
            else parameters.ExStyle &= ~WS_EX_NOACTIVATE;
            if (topMost) parameters.ExStyle |= WS_EX_TOPMOST;
            return parameters;
        }
    }

    protected override void WndProc(ref Message message) {
        if (noActivate && message.Msg == WM_MOUSEACTIVATE) {
            // MA_NOACTIVATE still delivers the mouse message. The EAT variant
            // would swallow the click and break interaction and dragging.
            message.Result = new IntPtr(MA_NOACTIVATE);
            return;
        }
        base.WndProc(ref message);
    }
}
'@
  Add-Type -TypeDefinition $petWindowCode -Language CSharp -ReferencedAssemblies @(
    [System.Windows.Forms.Form].Assembly.Location,
    [System.Windows.Forms.Message].Assembly.Location,
    [System.Drawing.Point].Assembly.Location,
    [System.ComponentModel.Component].Assembly.Location
  )
}

function Connect-PetContextMenu {
  param(
    [System.Windows.Forms.Form]$Form,
    [System.Windows.Forms.ContextMenuStrip]$Menu
  )
  # Do not assign Form.ContextMenuStrip or pass a source control to Show:
  # WinForms can activate that control's top-level form before opening a menu.
  $petContextMenu = $Menu
  $Form.Add_MouseUp({
    param($sender, $event)
    if ($event.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
      $petContextMenu.Show($sender.PointToScreen($event.Location))
    }
  }.GetNewClosure())
}
