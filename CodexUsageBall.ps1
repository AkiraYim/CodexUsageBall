param(
    [switch]$PrintUsage
)

$ErrorActionPreference = 'Stop'

function Get-CodexUsage {
    function Get-TailLines([string]$path, [int]$maxBytes = 8388608) {
        $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        $stream = New-Object System.IO.FileStream(
            $path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            $share
        )

        try {
            $start = [math]::Max(0, $stream.Length - $maxBytes)
            $stream.Position = $start
            $buffer = New-Object byte[] ([int]($stream.Length - $start))
            $offset = 0
            while ($offset -lt $buffer.Length) {
                $read = $stream.Read($buffer, $offset, $buffer.Length - $offset)
                if ($read -le 0) {
                    break
                }
                $offset += $read
            }

            $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $offset)
            $lines = @($text -split '\r?\n')
            if ($start -gt 0 -and $lines.Count -gt 0) {
                $lines = @($lines | Select-Object -Skip 1)
            }
            return $lines
        }
        finally {
            $stream.Dispose()
        }
    }

    $sessionsRoot = Join-Path $env:USERPROFILE '.codex\sessions'
    $result = [ordered]@{
        available = $false
        primaryUsed = 0
        primaryWindowMinutes = 300
        primaryResetsAt = 0
        secondaryUsed = 0
        secondaryWindowMinutes = 10080
        secondaryResetsAt = 0
        planType = $null
        updatedAt = $null
        source = $null
    }

    if (-not (Test-Path -LiteralPath $sessionsRoot)) {
        return [pscustomobject]$result
    }

    $allFiles = @()
    for ($daysAgo = 0; $daysAgo -lt 8; $daysAgo++) {
        $date = (Get-Date).AddDays(-$daysAgo)
        $dateFolder = Join-Path $sessionsRoot ('{0:yyyy/MM/dd}' -f $date)
        if (Test-Path -LiteralPath $dateFolder) {
            $allFiles += @(Get-ChildItem -LiteralPath $dateFolder -Filter '*.jsonl' -File)
        }
    }

    if ($allFiles.Count -eq 0) {
        $allFiles = @(Get-ChildItem -LiteralPath $sessionsRoot -Recurse -Filter '*.jsonl' -File)
    }

    $files = @($allFiles | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 5)

    $latestTimestamp = [DateTimeOffset]::MinValue

    foreach ($file in $files) {
        $lines = @(Get-TailLines $file.FullName)
        for ($index = $lines.Count - 1; $index -ge 0; $index--) {
            $line = $lines[$index]
            if ($line -notmatch '^\{"timestamp":"[^"]+","type":"event_msg","payload":\{"type":"token_count"') {
                continue
            }

            try {
                $entry = $line | ConvertFrom-Json
                $limits = $entry.payload.rate_limits
                if ($null -eq $limits.primary -and $null -eq $limits.secondary) {
                    continue
                }

                $entryTimestamp = [DateTimeOffset]::MinValue
                if (-not [DateTimeOffset]::TryParse(
                    [string]$entry.timestamp,
                    [ref]$entryTimestamp
                )) {
                    continue
                }

                if ($entryTimestamp -le $latestTimestamp) {
                    break
                }

                $result.available = $true
                $result.updatedAt = $entry.timestamp
                $result.source = $file.FullName
                $result.planType = $limits.plan_type

                if ($null -ne $limits.primary) {
                    $result.primaryUsed = [double]$limits.primary.used_percent
                    $result.primaryWindowMinutes = [int]$limits.primary.window_minutes
                    $result.primaryResetsAt = [long]$limits.primary.resets_at
                }

                if ($null -ne $limits.secondary) {
                    $result.secondaryUsed = [double]$limits.secondary.used_percent
                    $result.secondaryWindowMinutes = [int]$limits.secondary.window_minutes
                    $result.secondaryResetsAt = [long]$limits.secondary.resets_at
                }

                $latestTimestamp = $entryTimestamp
                break
            }
            catch {
                continue
            }
        }
    }

    return [pscustomobject]$result
}

if ($PrintUsage) {
    Get-CodexUsage | ConvertTo-Json
    exit 0
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class FullscreenMonitor {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MONITORINFO {
        public int Size;
        public RECT Monitor;
        public RECT Work;
        public uint Flags;
    }

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromWindow(IntPtr hWnd, uint flags);

    [DllImport("user32.dll")]
    private static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr hWnd, StringBuilder className, int maxCount);

    public static IntPtr GetWindowMonitor(IntPtr hWnd) {
        return MonitorFromWindow(hWnd, 2);
    }

    public static bool IsForegroundFullscreenOnMonitor(IntPtr targetMonitor, IntPtr ownWindow) {
        IntPtr foreground = GetForegroundWindow();
        if (foreground == IntPtr.Zero || foreground == ownWindow) {
            return false;
        }

        StringBuilder className = new StringBuilder(256);
        GetClassName(foreground, className, className.Capacity);
        string foregroundClass = className.ToString();
        if (foregroundClass == "Progman" || foregroundClass == "WorkerW") {
            return false;
        }

        IntPtr foregroundMonitor = MonitorFromWindow(foreground, 2);
        if (foregroundMonitor != targetMonitor) {
            return false;
        }

        RECT windowRect;
        if (!GetWindowRect(foreground, out windowRect)) {
            return false;
        }

        MONITORINFO monitorInfo = new MONITORINFO();
        monitorInfo.Size = Marshal.SizeOf(typeof(MONITORINFO));
        if (!GetMonitorInfo(targetMonitor, ref monitorInfo)) {
            return false;
        }

        const int tolerance = 2;
        return windowRect.Left <= monitorInfo.Monitor.Left + tolerance
            && windowRect.Top <= monitorInfo.Monitor.Top + tolerance
            && windowRect.Right >= monitorInfo.Monitor.Right - tolerance
            && windowRect.Bottom >= monitorInfo.Monitor.Bottom - tolerance;
    }
}
'@

$createdNew = $false
$instanceMutex = New-Object System.Threading.Mutex($true, 'CodexUsageBall.SingleInstance', [ref]$createdNew)
if (-not $createdNew) {
    exit 0
}

[xml]$xaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Codex Usage"
    Width="76"
    Height="76"
    WindowStyle="None"
    AllowsTransparency="True"
    Background="Transparent"
    Topmost="True"
    ShowInTaskbar="False"
    ResizeMode="NoResize">
    <Grid>
        <Popup x:Name="UsagePopup"
               PlacementTarget="{Binding ElementName=Ball}"
               Placement="Top"
               HorizontalOffset="-242"
               VerticalOffset="-8"
               AllowsTransparency="True"
               StaysOpen="True"
               IsOpen="False">
        <Border x:Name="Panel"
                Width="318"
                Height="220"
                Background="#FC17181B"
                BorderBrush="#3A3C42"
                BorderThickness="1"
                CornerRadius="8">
            <Grid Margin="18">
                <Grid.RowDefinitions>
                    <RowDefinition Height="34"/>
                    <RowDefinition Height="72"/>
                    <RowDefinition Height="72"/>
                    <RowDefinition Height="24"/>
                </Grid.RowDefinitions>
                <Grid Grid.Row="0">
                    <TextBlock Text="CODEX 用量"
                               Foreground="#F7F7F5"
                               FontFamily="Segoe UI"
                               FontSize="15"
                               FontWeight="SemiBold"
                               VerticalAlignment="Top"/>
                    <StackPanel Orientation="Horizontal"
                                HorizontalAlignment="Right"
                                VerticalAlignment="Top">
                        <TextBlock x:Name="PlanText"
                                   Text=""
                                   Foreground="#7FA7FF"
                                   FontFamily="Segoe UI"
                                   FontSize="11"
                                   Margin="0,4,10,0"/>
                        <Button x:Name="PanelRefreshButton"
                                Width="58"
                                Height="26"
                                Background="#2D5B9A"
                                BorderBrush="#75A7EF"
                                BorderThickness="1"
                                Foreground="#FFFFFF"
                                FontFamily="Segoe UI Symbol"
                                FontSize="12"
                                FontWeight="SemiBold"
                                Cursor="Hand"
                                ToolTip="立即刷新用量"
                                Content="↻ 刷新">
                            <Button.Resources>
                                <Style TargetType="Border">
                                    <Setter Property="CornerRadius" Value="6"/>
                                </Style>
                            </Button.Resources>
                        </Button>
                    </StackPanel>
                </Grid>
                <Grid Grid.Row="1">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="28"/>
                        <RowDefinition Height="10"/>
                        <RowDefinition Height="24"/>
                    </Grid.RowDefinitions>
                    <TextBlock Text="5 小时剩余"
                               Foreground="#D5D7DC"
                               FontSize="13"
                               VerticalAlignment="Center"/>
                    <TextBlock x:Name="PrimaryPercent"
                               Text="--%"
                               Foreground="#FFFFFF"
                               FontSize="16"
                               FontWeight="SemiBold"
                               HorizontalAlignment="Right"
                               VerticalAlignment="Center"/>
                    <Border Grid.Row="1" Background="#2B2D32" CornerRadius="3">
                        <Border x:Name="PrimaryBar"
                                Width="0"
                                HorizontalAlignment="Left"
                                Background="#7FA7FF"
                                CornerRadius="3"/>
                    </Border>
                    <TextBlock x:Name="PrimaryReset"
                               Grid.Row="2"
                               Text="等待 Codex 用量数据"
                               Foreground="#989CA6"
                               FontSize="11"
                               VerticalAlignment="Bottom"/>
                </Grid>
                <Grid Grid.Row="2">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="28"/>
                        <RowDefinition Height="10"/>
                        <RowDefinition Height="24"/>
                    </Grid.RowDefinitions>
                    <TextBlock Text="一周剩余"
                               Foreground="#D5D7DC"
                               FontSize="13"
                               VerticalAlignment="Center"/>
                    <TextBlock x:Name="SecondaryPercent"
                               Text="--%"
                               Foreground="#FFFFFF"
                               FontSize="16"
                               FontWeight="SemiBold"
                               HorizontalAlignment="Right"
                               VerticalAlignment="Center"/>
                    <Border Grid.Row="1" Background="#2B2D32" CornerRadius="3">
                        <Border x:Name="SecondaryBar"
                                Width="0"
                                HorizontalAlignment="Left"
                                Background="#B7CCFF"
                                CornerRadius="3"/>
                    </Border>
                    <TextBlock x:Name="SecondaryReset"
                               Grid.Row="2"
                               Text="等待 Codex 用量数据"
                               Foreground="#989CA6"
                               FontSize="11"
                               VerticalAlignment="Bottom"/>
                </Grid>
                <TextBlock x:Name="UpdatedText"
                           Grid.Row="3"
                           Text="每 60 秒自动刷新"
                           Foreground="#727680"
                           FontSize="10"
                           VerticalAlignment="Center"/>
            </Grid>
        </Border>
        </Popup>

        <Border x:Name="Ball"
                Width="64"
                Height="64"
                HorizontalAlignment="Right"
                VerticalAlignment="Bottom"
                CornerRadius="32"
                Background="#FC111318"
                BorderThickness="0">
            <Grid Width="64" Height="64">
                <Ellipse Width="52"
                         Height="52"
                         Stroke="#303640"
                         StrokeThickness="4"/>
                <Ellipse x:Name="UsageRing"
                         Width="52"
                         Height="52"
                         Stroke="#7FA7FF"
                         StrokeThickness="4"
                         StrokeStartLineCap="Round"
                         StrokeEndLineCap="Round"
                         RenderTransformOrigin="0.5,0.5">
                    <Ellipse.RenderTransform>
                        <RotateTransform Angle="-90"/>
                    </Ellipse.RenderTransform>
                </Ellipse>
                <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center">
                    <TextBlock Text="CODEX"
                               Foreground="#9CA3AF"
                               FontFamily="Segoe UI"
                               FontSize="8"
                               FontWeight="SemiBold"
                               HorizontalAlignment="Center"/>
                    <TextBlock x:Name="BallPercent"
                               Text="--%"
                               Foreground="White"
                               FontFamily="Segoe UI"
                               FontSize="15"
                               FontWeight="Bold"
                               HorizontalAlignment="Center"/>
                </StackPanel>
            </Grid>
        </Border>
    </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
$panel = $window.FindName('Panel')
$usagePopup = $window.FindName('UsagePopup')
$ball = $window.FindName('Ball')
$ballPercent = $window.FindName('BallPercent')
$usageRing = $window.FindName('UsageRing')
$primaryPercent = $window.FindName('PrimaryPercent')
$primaryBar = $window.FindName('PrimaryBar')
$primaryReset = $window.FindName('PrimaryReset')
$secondaryPercent = $window.FindName('SecondaryPercent')
$secondaryBar = $window.FindName('SecondaryBar')
$secondaryReset = $window.FindName('SecondaryReset')
$updatedText = $window.FindName('UpdatedText')
$planText = $window.FindName('PlanText')
$panelRefreshButton = $window.FindName('PanelRefreshButton')

$workArea = [Windows.SystemParameters]::WorkArea
$window.Left = $workArea.Right - $window.Width - 20
$window.Top = $workArea.Bottom - $window.Height - 20

function Format-ResetTime([long]$epochSeconds) {
    if ($epochSeconds -le 0) {
        return '重置时间未知'
    }

    $reset = [DateTimeOffset]::FromUnixTimeSeconds($epochSeconds).ToLocalTime()
    $remaining = $reset - [DateTimeOffset]::Now
    if ($remaining.TotalSeconds -le 0) {
        return '即将重置'
    }

    if ($remaining.TotalDays -ge 1) {
        return ('{0:ddd HH:mm} 重置 · 还剩 {1}天 {2}小时' -f $reset, [math]::Floor($remaining.TotalDays), $remaining.Hours)
    }

    return ('{0:HH:mm} 重置 · 还剩 {1}小时 {2}分' -f $reset, [math]::Floor($remaining.TotalHours), $remaining.Minutes)
}

function Get-UsageColor([double]$percentRemaining) {
    if ($percentRemaining -le 10) {
        return '#EF4444'
    }
    if ($percentRemaining -le 30) {
        return '#F59E0B'
    }
    return '#7FA7FF'
}

function Set-UsageRing([double]$percent) {
    $clamped = [math]::Max(0, [math]::Min(100, $percent))
    $circumferenceInStrokeUnits = 37.699
    $filled = $circumferenceInStrokeUnits * $clamped / 100
    $empty = [math]::Max(0.01, $circumferenceInStrokeUnits - $filled)
    $usageRing.StrokeDashArray = New-Object Windows.Media.DoubleCollection (,[double[]]@($filled, $empty))
}

function Set-UsageDisplay($usage) {
    if (-not $usage.available) {
        $ballPercent.Text = '--%'
        $primaryPercent.Text = '--%'
        $secondaryPercent.Text = '--%'
        $primaryReset.Text = '打开 Codex 并发送一条消息后刷新'
        $secondaryReset.Text = '尚未找到限额记录'
        $updatedText.Text = '右键可立即刷新'
        Set-UsageRing 0
        return
    }

    $primary = [math]::Round([math]::Max(0, [math]::Min(100, 100 - $usage.primaryUsed)))
    $secondary = [math]::Round([math]::Max(0, [math]::Min(100, 100 - $usage.secondaryUsed)))
    $ballPercent.Text = "$primary%"
    $primaryPercent.Text = "$primary%"
    $secondaryPercent.Text = "$secondary%"
    $primaryBar.Width = 2.64 * [math]::Min(100, $primary)
    $secondaryBar.Width = 2.64 * [math]::Min(100, $secondary)
    $primaryReset.Text = Format-ResetTime $usage.primaryResetsAt
    $secondaryReset.Text = Format-ResetTime $usage.secondaryResetsAt
    $planText.Text = if ($usage.planType) { $usage.planType.ToUpperInvariant() } else { '' }
    $sourceTime = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse([string]$usage.updatedAt, [ref]$sourceTime)) {
        $updatedText.Text = '数据截至 {0:HH:mm:ss} · 每 60 秒扫描' -f $sourceTime.ToLocalTime()
    }
    else {
        $updatedText.Text = '数据时间未知 · 每 60 秒扫描'
    }

    $color = Get-UsageColor $primary
    $brush = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($color))
    $primaryBar.Background = $brush
    $arcColor = if ($primary -gt 30) { '#7FA7FF' } else { $color }
    $usageRing.Stroke = New-Object Windows.Media.SolidColorBrush (
        [Windows.Media.ColorConverter]::ConvertFromString($arcColor)
    )
    Set-UsageRing $primary
}

$script:usagePowerShell = $null
$script:usageAsyncResult = $null
$usageFunctionText = ${function:Get-CodexUsage}.ToString()

function Start-UsageRefresh {
    if ($null -ne $script:usageAsyncResult -and -not $script:usageAsyncResult.IsCompleted) {
        return
    }

    if ($null -ne $script:usagePowerShell) {
        $script:usagePowerShell.Dispose()
    }

    $script:usagePowerShell = [PowerShell]::Create()
    $collectorScript = @"
function Get-CodexUsage {
$usageFunctionText
}
Get-CodexUsage | ConvertTo-Json -Compress
"@
    $null = $script:usagePowerShell.AddScript($collectorScript)
    $script:usageAsyncResult = $script:usagePowerShell.BeginInvoke()
    $panelRefreshButton.IsEnabled = $false
}

$panelRefreshButton.Add_Click({
    $updatedText.Text = '正在刷新...'
    Start-UsageRefresh
})

function Complete-UsageRefresh {
    if ($null -eq $script:usageAsyncResult -or -not $script:usageAsyncResult.IsCompleted) {
        return
    }

    try {
        $output = $script:usagePowerShell.EndInvoke($script:usageAsyncResult)
        $json = ($output | ForEach-Object { $_.ToString() }) -join ''
        if ($json) {
            Set-UsageDisplay ($json | ConvertFrom-Json)
        }
    }
    catch {
        $updatedText.Text = '刷新失败，将在稍后重试'
    }
    finally {
        $script:usagePowerShell.Dispose()
        $script:usagePowerShell = $null
        $script:usageAsyncResult = $null
        $panelRefreshButton.IsEnabled = $true
    }
}

function Toggle-Panel {
    $script:isExpanded = -not $script:isExpanded
    $usagePopup.IsOpen = $script:isExpanded
    if ($script:isExpanded) {
        Start-UsageRefresh
    }
}

function Close-Panel {
    if ($script:isExpanded) {
        $script:isExpanded = $false
        $usagePopup.IsOpen = $false
    }
}

$script:isExpanded = $false
$script:pointerDown = $false
$script:isDragging = $false
$script:dragStartCursor = $null
$script:dragStartLeft = 0.0
$script:dragStartTop = 0.0
$script:windowHandle = [IntPtr]::Zero
$script:ballMonitor = [IntPtr]::Zero
$script:fullscreenAutoHideEnabled = $false
$script:fullscreenDetectionCount = 0
$script:hiddenForFullscreen = $false

function Get-CursorPositionDip {
    $cursor = [System.Windows.Forms.Cursor]::Position
    $source = [Windows.PresentationSource]::FromVisual($window)
    if ($null -ne $source -and $null -ne $source.CompositionTarget) {
        return $source.CompositionTarget.TransformFromDevice.Transform(
            (New-Object Windows.Point($cursor.X, $cursor.Y))
        )
    }
    return New-Object Windows.Point($cursor.X, $cursor.Y)
}

function Clamp-WindowPosition {
    $source = [Windows.PresentationSource]::FromVisual($window)
    $scaleX = 1.0
    $scaleY = 1.0
    if ($null -ne $source -and $null -ne $source.CompositionTarget) {
        $scaleX = $source.CompositionTarget.TransformToDevice.M11
        $scaleY = $source.CompositionTarget.TransformToDevice.M22
    }

    $centerX = [int](($window.Left + ($window.Width / 2)) * $scaleX)
    $centerY = [int](($window.Top + ($window.Height / 2)) * $scaleY)
    $screen = [System.Windows.Forms.Screen]::FromPoint(
        (New-Object System.Drawing.Point($centerX, $centerY))
    )
    $area = $screen.WorkingArea
    $currentWorkArea = [pscustomobject]@{
        Left = $area.Left / $scaleX
        Top = $area.Top / $scaleY
        Right = $area.Right / $scaleX
        Bottom = $area.Bottom / $scaleY
    }

    $window.Left = [math]::Max(
        $currentWorkArea.Left,
        [math]::Min($window.Left, $currentWorkArea.Right - $window.Width)
    )
    $window.Top = [math]::Max(
        $currentWorkArea.Top,
        [math]::Min($window.Top, $currentWorkArea.Bottom - $window.Height)
    )
}

function Update-BallMonitor {
    if ($script:windowHandle -ne [IntPtr]::Zero) {
        $script:ballMonitor = [FullscreenMonitor]::GetWindowMonitor($script:windowHandle)
    }
}

function Update-FullscreenVisibility {
    if ($script:windowHandle -eq [IntPtr]::Zero -or $script:ballMonitor -eq [IntPtr]::Zero) {
        return
    }

    if (-not $script:fullscreenAutoHideEnabled) {
        $script:fullscreenDetectionCount = 0
        if ($script:hiddenForFullscreen) {
            $window.Visibility = [Windows.Visibility]::Visible
            $script:hiddenForFullscreen = $false
        }
        return
    }

    $shouldHide = [FullscreenMonitor]::IsForegroundFullscreenOnMonitor(
        $script:ballMonitor,
        $script:windowHandle
    )

    if ($shouldHide) {
        $script:fullscreenDetectionCount++
    }
    else {
        $script:fullscreenDetectionCount = 0
    }

    if ($script:fullscreenDetectionCount -ge 4 -and -not $script:hiddenForFullscreen) {
        Close-Panel
        $window.Visibility = [Windows.Visibility]::Hidden
        $script:hiddenForFullscreen = $true
    }
    elseif (-not $shouldHide -and $script:hiddenForFullscreen) {
        $window.Visibility = [Windows.Visibility]::Visible
        $script:hiddenForFullscreen = $false
    }
}

$ball.Add_MouseLeftButtonDown({
    param($sender, $eventArgs)

    $script:pointerDown = $true
    $script:isDragging = $false
    $script:dragStartCursor = Get-CursorPositionDip
    $script:dragStartLeft = $window.Left
    $script:dragStartTop = $window.Top
    $ball.CaptureMouse() | Out-Null
})

$ball.Add_MouseMove({
    param($sender, $eventArgs)
    if (-not $script:pointerDown -or $script:isExpanded) {
        return
    }

    $cursor = Get-CursorPositionDip
    $deltaX = $cursor.X - $script:dragStartCursor.X
    $deltaY = $cursor.Y - $script:dragStartCursor.Y

    if (-not $script:isDragging -and ([math]::Abs($deltaX) -gt 5 -or [math]::Abs($deltaY) -gt 5)) {
        $script:isDragging = $true
    }

    if ($script:isDragging) {
        $window.Left = $script:dragStartLeft + $deltaX
        $window.Top = $script:dragStartTop + $deltaY
    }
})

$ball.Add_MouseLeftButtonUp({
    param($sender, $eventArgs)
    if (-not $script:pointerDown) {
        return
    }

    $script:pointerDown = $false
    $ball.ReleaseMouseCapture()

    if ($script:isDragging) {
        Clamp-WindowPosition
        Update-BallMonitor
    }
})

$ball.Add_LostMouseCapture({
    $script:pointerDown = $false
})

$window.Add_MouseDoubleClick({
    param($sender, $eventArgs)
    if (-not $script:isDragging -and $eventArgs.ChangedButton -eq [Windows.Input.MouseButton]::Left) {
        Toggle-Panel
        $eventArgs.Handled = $true
    }
})

$window.Add_Deactivated({
    Close-Panel
})

$menu = New-Object System.Windows.Controls.ContextMenu
$refreshItem = New-Object System.Windows.Controls.MenuItem
$refreshItem.Header = '立即刷新'
$refreshItem.Add_Click({ Start-UsageRefresh })
$menu.Items.Add($refreshItem) | Out-Null

$fullscreenItem = New-Object System.Windows.Controls.MenuItem
$fullscreenItem.Header = '全屏时自动隐藏'
$fullscreenItem.IsCheckable = $true
$fullscreenItem.IsChecked = $script:fullscreenAutoHideEnabled
$fullscreenItem.Add_Click({
    $script:fullscreenAutoHideEnabled = $fullscreenItem.IsChecked
    Update-FullscreenVisibility
})
$menu.Items.Add($fullscreenItem) | Out-Null

$openFolderItem = New-Object System.Windows.Controls.MenuItem
$openFolderItem.Header = '打开程序目录'
$openFolderItem.Add_Click({
    Start-Process explorer.exe -ArgumentList $PSScriptRoot
})
$menu.Items.Add($openFolderItem) | Out-Null

$menu.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null
$exitItem = New-Object System.Windows.Controls.MenuItem
$exitItem.Header = '退出'
$exitItem.Add_Click({ $window.Close() })
$menu.Items.Add($exitItem) | Out-Null
$ball.ContextMenu = $menu

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(60)
$timer.Add_Tick({ Start-UsageRefresh })
$timer.Start()

$refreshPollTimer = New-Object Windows.Threading.DispatcherTimer
$refreshPollTimer.Interval = [TimeSpan]::FromMilliseconds(100)
$refreshPollTimer.Add_Tick({ Complete-UsageRefresh })
$refreshPollTimer.Start()

$fullscreenTimer = New-Object Windows.Threading.DispatcherTimer
$fullscreenTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$fullscreenTimer.Add_Tick({ Update-FullscreenVisibility })
$fullscreenTimer.Start()

$window.Add_Loaded({
    Clamp-WindowPosition
    $script:windowHandle = (New-Object Windows.Interop.WindowInteropHelper($window)).Handle
    Update-BallMonitor
    $window.Activate()
    Start-UsageRefresh
})
$window.Add_Closed({
    $timer.Stop()
    $refreshPollTimer.Stop()
    $fullscreenTimer.Stop()
    $usagePopup.IsOpen = $false
    if ($null -ne $script:usagePowerShell) {
        $script:usagePowerShell.Stop()
        $script:usagePowerShell.Dispose()
    }
    $instanceMutex.ReleaseMutex()
    $instanceMutex.Dispose()
})
$null = $window.ShowDialog()
