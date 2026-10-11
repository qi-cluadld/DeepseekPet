#Requires -Version 5.1
<#
  DeepSeek 桌面小宠物 / DeepSeek Desktop Pet  🐋
  ---------------------------------------------------------------
  * 纯 Windows 自带组件实现(WPF + PowerShell 5.1),无需安装任何依赖
  * 一只 DeepSeek 蓝鲸小精灵:待机漂浮摆尾 / 随机小动作 / 戳一戳有反应
  * 左键拖动移动,右键菜单(打招呼、摸摸头、喷水柱、吹泡泡、大小、游到别处、退出)
  * 不抢焦点(可在你打字时安静地待在角落)

  用法:
    powershell -NoProfile -ExecutionPolicy Bypass -File DeepSeekPet.ps1
    powershell ... -File DeepSeekPet.ps1 -Size 1.3          # 放大
    powershell ... -File DeepSeekPet.ps1 -Preview out        # 渲染静态预览图(检查外观)
    powershell ... -File DeepSeekPet.ps1 -SelfTest 20        # 自检 20 秒(自动跑一遍所有动作)
#>

[CmdletBinding()]
param(
    [string]$Preview,                 # 渲染预览图的输出目录
    [int]$SelfTest = 0,               # 自检运行秒数
    [switch]$PreviewAlpha,           # 预览图带透明通道(用于做图标)
    [double]$Size = 1.0,              # 宠物大小倍率
    [switch]$ActivateOnClick,         # 点击时允许抢焦点(默认不抢)
    [switch]$AllowMultiple            # 允许开多只
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- 程序集
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
try { Add-Type -AssemblyName System.Xaml } catch { }

$script:LogPath = Join-Path $env:TEMP 'DeepSeekPet.log'
$socialPath = Join-Path $PSScriptRoot 'social.ps1'
if (Test-Path -LiteralPath $socialPath) { . $socialPath }
$socialPath = Join-Path $PSScriptRoot 'social.ps1'
if (Test-Path -LiteralPath $socialPath) { . $socialPath }
function Write-PetLog([string]$msg) {
    try { Add-Content -LiteralPath $script:LogPath -Value ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $msg) -Encoding UTF8 } catch { }
}

# ---------------------------------------------------------------- 原生调用
try {
    Add-Type -Namespace 'DeepSeekPetNative' -Name 'Win32' -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
[DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
[DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
'@
} catch { Write-PetLog "Add-Type Win32 失败: $_" }

function Initialize-Dpi {
    try {
        if (-not [DeepSeekPetNative.Win32]::SetProcessDpiAwarenessContext([IntPtr](-4))) {
            [void][DeepSeekPetNative.Win32]::SetProcessDPIAware()
        }
    } catch {
        try { [void][DeepSeekPetNative.Win32]::SetProcessDPIAware() } catch { }
    }
}
function Get-CursorPoint {
    $p = New-Object DeepSeekPetNative.Win32+POINT
    if ([DeepSeekPetNative.Win32]::GetCursorPos([ref]$p)) { return @($p.X, $p.Y) }
    return @(0, 0)
}

# ---------------------------------------------------------------- 小工具
$script:Inv = [System.Globalization.CultureInfo]::InvariantCulture
function F([double]$v) { $v.ToString('0.###', $script:Inv) }
function Clamp01([double]$v) { if ($v -lt 0) { 0.0 } elseif ($v -gt 1) { 1.0 } else { $v } }
function Ease-InOut([double]$p) { $p = Clamp01 $p; $p * $p * (3 - 2 * $p) }

$script:Rng = New-Object System.Random
function Rand([double]$min, [double]$max) { $min + $script:Rng.NextDouble() * ($max - $min) }

function New-Gs([string]$color, [double]$offset) {
    $g = New-Object System.Windows.Media.GradientStop
    $g.Color = [System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString($color)
    $g.Offset = $offset
    return $g
}
function New-LinBrush([string[]]$colors, [double[]]$offsets, [double]$x1 = 0, [double]$y1 = 0, [double]$x2 = 1, [double]$y2 = 1) {
    $b = New-Object System.Windows.Media.LinearGradientBrush
    $b.StartPoint = New-Object System.Windows.Point($x1, $y1)
    $b.EndPoint = New-Object System.Windows.Point($x2, $y2)
    for ($i = 0; $i -lt $colors.Count; $i++) { [void]$b.GradientStops.Add((New-Gs $colors[$i] $offsets[$i])) }
    return $b
}
function New-RadBrush([string]$inner, [string]$outer, [double]$gx = 0.5, [double]$gy = 0.5, [double]$rx = 0.5, [double]$ry = 0.5) {
    $b = New-Object System.Windows.Media.RadialGradientBrush
    $b.GradientOrigin = New-Object System.Windows.Point($gx, $gy)
    $b.Center = New-Object System.Windows.Point($gx, $gy)
    $b.RadiusX = $rx
    $b.RadiusY = $ry
    [void]$b.GradientStops.Add((New-Gs $inner 0))
    [void]$b.GradientStops.Add((New-Gs $outer 1))
    return $b
}

$script:BodyData = 'M 48,132 C 48,104 66,90 94,90 C 128,90 160,98 176,116 C 186,128 186,146 178,152 C 168,174 142,186 114,186 C 84,186 52,176 48,152 C 46,144 46,138 48,132 Z'
$script:BellyData = 'M 56,148 C 72,172 100,186 122,186 C 148,186 168,170 178,148 C 168,160 146,170 120,170 C 94,170 70,158 56,148 Z'
$script:TailData = 'M 172,124 C 182,108 198,96 212,96 C 221,104 213,124 195,136 C 213,148 221,168 212,176 C 198,176 182,164 172,148 Z'
$script:FinData = 'M 87,153 C 76,159 66,173 70,185 C 82,187 96,179 102,167 C 100,159 93,153 87,153 Z'
$script:DropData = 'M 0,-9 C 5,-3 8,2 8,6 C 8,11 4,14 0,14 C -4,14 -8,11 -8,6 C -8,2 -5,-3 0,-9 Z'
$script:HeartData = 'M 0,9 C -11,2 -10,-7 -4.5,-9 C -1.5,-10 0,-8 0,-6 C 0,-8 1.5,-10 4.5,-9 C 10,-7 11,2 0,9 Z'

# ---------------------------------------------------------------- 界面(XAML)
$xaml = @'
<Canvas xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        x:Name="Root" Width="240" Height="240" ClipToBounds="False">

  <Canvas x:Name="PetWrap" Width="240" Height="240" Canvas.Left="0" Canvas.Top="0"
          RenderTransformOrigin="0.5,0.5" Cursor="Hand" ClipToBounds="False">
    <Canvas.RenderTransform>
      <TransformGroup>
        <ScaleTransform x:Name="TScale" ScaleX="1" ScaleY="1"/>
        <RotateTransform x:Name="TRot" Angle="0"/>
        <TranslateTransform x:Name="TTrans" X="0" Y="0"/>
      </TransformGroup>
    </Canvas.RenderTransform>
    <Canvas x:Name="Pet" Width="240" Height="240">

      <!-- 水光晕 -->
      <Ellipse Width="232" Height="232" Canvas.Left="4" Canvas.Top="4" Opacity="0.5" IsHitTestVisible="False">
        <Ellipse.Fill>
          <RadialGradientBrush>
            <GradientStop Color="#66B6D4FF" Offset="0.30"/>
            <GradientStop Color="#334D6BFE" Offset="0.68"/>
            <GradientStop Color="#002BC8FF" Offset="1"/>
          </RadialGradientBrush>
        </Ellipse.Fill>
      </Ellipse>

      <!-- 尾鳍(在身体后面) -->
      <Path x:Name="Tail" Data="{TAIL}" IsHitTestVisible="False">
        <Path.Fill>
          <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
            <GradientStop Color="#FF7B96FF" Offset="0"/>
            <GradientStop Color="#FF4360E8" Offset="0.55"/>
            <GradientStop Color="#FF2E45B8" Offset="1"/>
          </LinearGradientBrush>
        </Path.Fill>
        <Path.RenderTransform>
          <RotateTransform x:Name="TailRot" CenterX="178" CenterY="136" Angle="0"/>
        </Path.RenderTransform>
      </Path>

      <!-- 身体(深蓝鲸身) -->
      <Path x:Name="Body" Data="{BODY}" IsHitTestVisible="True">
        <Path.Fill>
          <LinearGradientBrush StartPoint="0.18,0.02" EndPoint="0.72,1">
            <GradientStop Color="#FF82A3FF" Offset="0"/>
            <GradientStop Color="#FF4D6BFE" Offset="0.42"/>
            <GradientStop Color="#FF3A55DC" Offset="1"/>
          </LinearGradientBrush>
        </Path.Fill>
        <Path.Effect>
          <DropShadowEffect Color="#7A1E38B4" BlurRadius="16" ShadowDepth="5" Direction="270" Opacity="0.5"/>
        </Path.Effect>
      </Path>

      <!-- 肚皮(浅色, 由身体形状裁剪) -->
      <Path x:Name="Belly" Data="{BELLY}" IsHitTestVisible="False">
        <Path.Fill>
          <LinearGradientBrush StartPoint="0.5,0" EndPoint="0.5,1">
            <GradientStop Color="#00FFFFFF" Offset="0"/>
            <GradientStop Color="#A6EAF1FF" Offset="0.5"/>
            <GradientStop Color="#D9F4F8FF" Offset="1"/>
          </LinearGradientBrush>
        </Path.Fill>
      </Path>

      <!-- 背部高光 -->
      <Path Data="{BODY}" IsHitTestVisible="False">
        <Path.Fill>
          <RadialGradientBrush GradientOrigin="0.30,0.14" Center="0.30,0.14" RadiusX="0.66" RadiusY="0.52">
            <GradientStop Color="#73FFFFFF" Offset="0"/>
            <GradientStop Color="#00FFFFFF" Offset="1"/>
          </RadialGradientBrush>
        </Path.Fill>
      </Path>

      <!-- 胸鳍 -->
      <Path x:Name="Fin" Data="{FIN}" IsHitTestVisible="False">
        <Path.Fill>
          <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
            <GradientStop Color="#FF6D8BFF" Offset="0"/>
            <GradientStop Color="#FF3B58E4" Offset="1"/>
          </LinearGradientBrush>
        </Path.Fill>
        <Path.RenderTransform>
          <RotateTransform x:Name="FinRot" CenterX="96" CenterY="156" Angle="0"/>
        </Path.RenderTransform>
      </Path>

      <!-- 喷气孔 -->
      <Ellipse Width="13" Height="6" Canvas.Left="100" Canvas.Top="88" Fill="#8C1F3480" IsHitTestVisible="False">
        <Ellipse.RenderTransform>
          <RotateTransform CenterX="7.5" CenterY="3.5" Angle="-10"/>
        </Ellipse.RenderTransform>
      </Ellipse>

      <!-- 眼睛(睁) -->
      <Canvas x:Name="EyeOpen" Width="240" Height="240" RenderTransformOrigin="0.5,0.5" IsHitTestVisible="False">
        <Canvas.RenderTransform>
          <TransformGroup>
            <ScaleTransform x:Name="EyeScale" ScaleX="1" ScaleY="1"/>
            <TranslateTransform x:Name="EyeLook" X="0" Y="0"/>
          </TransformGroup>
        </Canvas.RenderTransform>
        <Ellipse Width="27" Height="30" Canvas.Left="80.5" Canvas.Top="109.5">
          <Ellipse.Fill>
            <LinearGradientBrush StartPoint="0.2,0" EndPoint="0.8,1">
              <GradientStop Color="#FF26325C" Offset="0"/>
              <GradientStop Color="#FF0E1630" Offset="1"/>
            </LinearGradientBrush>
          </Ellipse.Fill>
        </Ellipse>
        <Ellipse Width="27" Height="30" Canvas.Left="120.5" Canvas.Top="109.5">
          <Ellipse.Fill>
            <LinearGradientBrush StartPoint="0.2,0" EndPoint="0.8,1">
              <GradientStop Color="#FF26325C" Offset="0"/>
              <GradientStop Color="#FF0E1630" Offset="1"/>
            </LinearGradientBrush>
          </Ellipse.Fill>
        </Ellipse>
        <Ellipse Width="10" Height="10" Canvas.Left="85" Canvas.Top="113" Fill="#FFFFFFFF" Opacity="0.95"/>
        <Ellipse Width="10" Height="10" Canvas.Left="125" Canvas.Top="113" Fill="#FFFFFFFF" Opacity="0.95"/>
        <Ellipse Width="4.5" Height="4.5" Canvas.Left="100" Canvas.Top="127" Fill="#FFFFFFFF" Opacity="0.6"/>
        <Ellipse Width="4.5" Height="4.5" Canvas.Left="140" Canvas.Top="127" Fill="#FFFFFFFF" Opacity="0.6"/>
      </Canvas>

      <!-- 眼睛(笑成弯月) -->
      <Canvas x:Name="EyeHappy" Width="240" Height="240" Visibility="Collapsed" IsHitTestVisible="False">
        <Path Data="M -12,3 Q 0,-10 12,3" Stroke="#FF16213E" StrokeThickness="4.2"
              StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round">
          <Path.RenderTransform>
            <TranslateTransform X="94" Y="125"/>
          </Path.RenderTransform>
        </Path>
        <Path Data="M -12,3 Q 0,-10 12,3" Stroke="#FF16213E" StrokeThickness="4.2"
              StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round">
          <Path.RenderTransform>
            <TranslateTransform X="134" Y="125"/>
          </Path.RenderTransform>
        </Path>
      </Canvas>

      <!-- 嘴 -->
      <Canvas x:Name="Mouth" Width="240" Height="240" IsHitTestVisible="False">
        <Path x:Name="MouthSmile" Data="M -10,0 Q 0,10 10,0" Stroke="#FF16213E" StrokeThickness="3.4"
              StrokeStartLineCap="Round" StrokeEndLineCap="Round">
          <Path.RenderTransform>
            <TranslateTransform X="114" Y="152"/>
          </Path.RenderTransform>
        </Path>
        <Path x:Name="MouthFlat" Data="M -8,0 L 8,0" Stroke="#FF16213E" StrokeThickness="3.4"
              StrokeStartLineCap="Round" StrokeEndLineCap="Round" Visibility="Collapsed">
          <Path.RenderTransform>
            <TranslateTransform X="114" Y="153"/>
          </Path.RenderTransform>
        </Path>
        <Ellipse x:Name="MouthOpen" Width="13" Height="15" Canvas.Left="107.5" Canvas.Top="145" Fill="#FF16213E" Visibility="Collapsed"/>
      </Canvas>

      <!-- 腮红 -->
      <Canvas x:Name="Blush" Width="240" Height="240" Opacity="0" IsHitTestVisible="False">
        <Ellipse Width="26" Height="13" Canvas.Left="65" Canvas.Top="136">
          <Ellipse.Fill>
            <RadialGradientBrush>
              <GradientStop Color="#FFFF8FB4" Offset="0"/>
              <GradientStop Color="#00FF8FB4" Offset="1"/>
            </RadialGradientBrush>
          </Ellipse.Fill>
        </Ellipse>
        <Ellipse Width="26" Height="13" Canvas.Left="137" Canvas.Top="136">
          <Ellipse.Fill>
            <RadialGradientBrush>
              <GradientStop Color="#FFFF8FB4" Offset="0"/>
              <GradientStop Color="#00FF8FB4" Offset="1"/>
            </RadialGradientBrush>
          </Ellipse.Fill>
        </Ellipse>
      </Canvas>
    </Canvas>
  </Canvas>

  <!-- 说话气泡(放在 PetWrap 之外, 所以不会跟着宠物一起旋转) -->
  <Border x:Name="SayBubble" Canvas.Left="16" Canvas.Top="2" MaxWidth="208" CornerRadius="14"
          Background="#F2FFFFFF" BorderBrush="#4D4D6BFE" BorderThickness="1.2" Padding="10,6"
          Visibility="Collapsed" IsHitTestVisible="False">
    <Border.Effect>
      <DropShadowEffect Color="#4D10306E" BlurRadius="10" ShadowDepth="2" Direction="270" Opacity="0.45"/>
    </Border.Effect>
    <TextBlock x:Name="SayText" FontFamily="Microsoft YaHei UI" FontSize="14" Foreground="#FF10265E" TextWrapping="Wrap"/>
  </Border>
  <Canvas x:Name="OrbitLayer" Width="240" Height="240" IsHitTestVisible="False"/>
  <Canvas x:Name="ParticleLayer" Width="240" Height="240" IsHitTestVisible="False"/>
</Canvas>
'@


$xaml = $xaml.Replace('{BODY}', $script:BodyData).Replace('{BELLY}', $script:BellyData).Replace('{TAIL}', $script:TailData).Replace('{FIN}', $script:FinData)
$root = [System.Windows.Markup.XamlReader]::Parse($xaml)

function N([string]$name) {
    $el = $root.FindName($name)
    if (-not $el) { throw "找不到界面元素: $name" }
    return $el
}
$PetWrap = N 'PetWrap'
$Pet = N 'Pet'
$Pet.CacheMode = New-Object System.Windows.Media.BitmapCache
$Pet.CacheMode.RenderAtScale = 1.0
$Pet.CacheMode.EnableClearType = $false
$TScale = N 'TScale'; $TRot = N 'TRot'; $TTrans = N 'TTrans'
$Body = N 'Body'
$Tail = N 'Tail'; $TailRot = N 'TailRot'
$Fin = N 'Fin'; $FinRot = N 'FinRot'
$Belly = N 'Belly'
$Belly.Clip = [System.Windows.Media.Geometry]::Parse($script:BodyData)
$EyeOpen = N 'EyeOpen'; $EyeHappy = N 'EyeHappy'; $EyeScale = N 'EyeScale'; $EyeLook = N 'EyeLook'
$Mouth = N 'Mouth'; $MouthSmile = N 'MouthSmile'; $MouthFlat = N 'MouthFlat'; $MouthOpen = N 'MouthOpen'
$Blush = N 'Blush'
$OrbitLayer = N 'OrbitLayer'; $ParticleLayer = N 'ParticleLayer'
$SayBubble = N 'SayBubble'; $SayText = N 'SayText'
# ---------------------------------------------------------------- 计时元素
$script:Orbit = New-Object System.Collections.ArrayList
$script:Orbit = New-Object System.Collections.ArrayList
function Initialize-Orbit {
    $i = 0
    foreach ($phase in @(0.5, 2.6, 4.7)) {
        $b = New-Object System.Windows.Shapes.Ellipse
        $b.Width = 16; $b.Height = 16
        $b.Fill = New-RadBrush -inner '#4DFFFFFF' -outer '#2E7FB4FF' -gx 0.34 -gy 0.30 -rx 0.5 -ry 0.5
        $b.Stroke = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString('#73A8C8FF'))
        $b.StrokeThickness = 1.4
        $b.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.5)
        $rt = New-Object System.Windows.Media.RotateTransform(0)
        $b.RenderTransform = $rt
        $b.IsHitTestVisible = $false
        [void]$OrbitLayer.Children.Add($b)
        [void]$script:Orbit.Add(@{
                El = $b; Rot = $rt; Phase = $phase
                Speed = 0.32 + 0.06 * $i
                Radius = 90.0 + 9.0 * $i
            })
        $i++
    }
}
Initialize-Orbit

$script:Particles = New-Object System.Collections.ArrayList

function New-Particle {
    param(
        [ValidateSet('bubble', 'drop', 'heart', 'z')][string]$Kind,
        [double]$X, [double]$Y, [double]$VX, [double]$VY, [double]$G,
        [double]$Life, [double]$S0, [double]$S1, [double]$Spin
    )
    $el = $null
    $offX = 0.0; $offY = 0.0
    switch ($Kind) {
        'bubble' {
            $el = New-Object System.Windows.Shapes.Ellipse
            $el.Width = 16; $el.Height = 16
            $offX = 8.0; $offY = 8.0
            $el.Fill = New-RadBrush -inner '#59FFFFFF' -outer '#2687B8FF' -gx 0.34 -gy 0.30 -rx 0.5 -ry 0.5
            $el.Stroke = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString('#80BFD8FF'))
            $el.StrokeThickness = 1.3
        }
        'drop' {
            $el = New-Object System.Windows.Shapes.Path
            $el.Data = [System.Windows.Media.Geometry]::Parse($script:DropData)
            $el.Fill = New-LinBrush -colors @('#FFCFE4FF', '#FF4D6BFE') -offsets @(0, 1)
        }
        'heart' {
            $el = New-Object System.Windows.Shapes.Path
            $el.Data = [System.Windows.Media.Geometry]::Parse($script:HeartData)
            $el.Fill = New-LinBrush -colors @('#FFFF9EC2', '#FFE0658C') -offsets @(0, 1)
        }
        'z' {
            $el = New-Object System.Windows.Controls.TextBlock
            $el.Text = 'Z'
            $el.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe UI')
            $el.FontWeight = [System.Windows.FontWeights]::Bold
            $el.FontSize = 17
            $el.Foreground = New-LinBrush -colors @('#FFE6EEFF', '#FF6D8BFF') -offsets @(0, 1)
        }
    }
    $el.IsHitTestVisible = $false
    $sc = New-Object System.Windows.Media.ScaleTransform($S0, $S0)
    $rt = New-Object System.Windows.Media.RotateTransform(0)
    $tg = New-Object System.Windows.Media.TransformGroup
    [void]$tg.Children.Add($sc)
    [void]$tg.Children.Add($rt)
    $el.RenderTransformOrigin = New-Object System.Windows.Point(0, 0)
    $el.RenderTransform = $tg
    $el.Opacity = 1.0
    [System.Windows.Controls.Canvas]::SetLeft($el, $X + $offX)
    [System.Windows.Controls.Canvas]::SetTop($el, $Y + $offY)
    [void]$ParticleLayer.Children.Add($el)
    [void]$script:Particles.Add(@{
            El = $el; X = $X; Y = $Y; VX = $VX; VY = $VY; G = $G
            Life = 0.0; MaxLife = $Life; S0 = $S0; S1 = $S1; Spin = $Spin
            Sc = $sc; Rot = $rt; OX = $offX; OY = $offY
        })
}

function Clear-Particles {
    foreach ($p in @($script:Particles)) { [void]$ParticleLayer.Children.Remove($p.El) }
    $script:Particles.Clear()
}

# 喷水柱:从喷气孔向上冲出的水珠和泡泡
function Spawn-Spout([int]$n) {
    for ($i = 0; $i -lt $n; $i++) {
        $kind = if ($i % 3 -eq 0) { 'bubble' } else { 'drop' }
        New-Particle -Kind $kind -X (104 + (Rand -7 7)) -Y (86 + (Rand -5 5)) `
            -VX (Rand -36 36) -VY (Rand -215 -135) -G 330 `
            -Life (Rand 0.6 1.05) -S0 (Rand 0.5 0.9) -S1 (Rand 0.35 0.6) -Spin (Rand -100 100)
    }
}

# 落水溅起的水花
function Spawn-Splash([int]$n) {
    for ($i = 0; $i -lt $n; $i++) {
        $dir = if ($i % 2 -eq 0) { 1 } else { -1 }
        New-Particle -Kind 'drop' -X (122 + (Rand -22 22)) -Y (180 + (Rand -8 8)) `
            -VX ($dir * (Rand 18 70)) -VY (Rand -155 -85) -G 430 `
            -Life (Rand 0.5 0.85) -S0 (Rand 0.4 0.7) -S1 (Rand 0.3 0.5) -Spin (Rand -140 140)
    }
}

# 慢慢上浮的泡泡
function Spawn-Bubble([int]$n, [double]$bx = 104, [double]$by = 92) {
    for ($i = 0; $i -lt $n; $i++) {
        New-Particle -Kind 'bubble' -X ($bx + (Rand -11 11)) -Y ($by + (Rand -7 9)) `
            -VX (Rand -13 13) -VY (Rand -42 -22) -G -16 `
            -Life (Rand 1.1 1.9) -S0 (Rand 0.3 0.55) -S1 (Rand 0.7 1.05) -Spin (Rand -30 30)
    }
}

function Spawn-Hearts([int]$n) {
    for ($i = 0; $i -lt $n; $i++) {
        New-Particle -Kind 'heart' -X (120 + (Rand -48 48)) -Y (128 + (Rand -14 14)) `
            -VX (Rand -24 24) -VY (Rand -66 -36) -G -8 `
            -Life (Rand 0.9 1.4) -S0 (Rand 0.3 0.5) -S1 (Rand 0.9 1.25) -Spin (Rand -70 70)
    }
}

function Spawn-Z {
    New-Particle -Kind 'z' -X (Rand 142 158) -Y (Rand 88 102) `
        -VX (Rand 9 20) -VY (Rand -24 -14) -G -2 `
        -Life (Rand 1.6 2.1) -S0 (Rand 0.6 0.8) -S1 (Rand 1.3 1.7) -Spin 0
}

# ---------------------------------------------------------------- 表情
$script:CurExpr = ''
$script:EyeBase = 1.0
function Show-Mouth([string]$which) {
    $MouthSmile.Visibility = if ($which -eq 'smile') { 'Visible' } else { 'Collapsed' }
    $MouthFlat.Visibility = if ($which -eq 'flat') { 'Visible' } else { 'Collapsed' }
    $MouthOpen.Visibility = if ($which -eq 'open') { 'Visible' } else { 'Collapsed' }
}
function Set-Expression([string]$name) {
    if ($script:CurExpr -eq $name) { return }
    $script:CurExpr = $name
    switch ($name) {
        'happy' {
            $EyeOpen.Visibility = 'Collapsed'; $EyeHappy.Visibility = 'Visible'
            Show-Mouth 'smile'; $script:EyeBase = 1.0
        }
        'sleepy' {
            $EyeOpen.Visibility = 'Visible'; $EyeHappy.Visibility = 'Collapsed'
            Show-Mouth 'flat'; $script:EyeBase = 0.07
        }
        'surprised' {
            $EyeOpen.Visibility = 'Visible'; $EyeHappy.Visibility = 'Collapsed'
            Show-Mouth 'open'; $script:EyeBase = 1.2
        }
        default {
            $EyeOpen.Visibility = 'Visible'; $EyeHappy.Visibility = 'Collapsed'
            Show-Mouth 'smile'; $script:EyeBase = 1.0
        }
    }
}

# ---------------------------------------------------------------- 状态
$script:Win = $null
$script:T = 0.0
$script:State = 'idle'
$script:StateT = 0.0
$script:StateDur = 0.0
$script:LastAction = ''
$script:NextAction = 5.0
$script:BlinkT = -1.0
$script:NextBlink = 3.0
$script:PatT = -1.0
$script:ZTimer = 0.0
$script:Sleepy = $false
$script:IdleSince = 0.0
$script:ExprForce = ''
$script:ExprUntil = 0.0
$script:WanderFrom = 0.0
$script:WanderTo = 0.0
$script:WanderDir = 1.0
$script:PatCount = 0
$script:ErrorCount = 0

function Reset-PetState {
    Clear-Particles
    $script:State = 'idle'; $script:StateT = 0.0; $script:StateDur = 0.0
    $script:Sleepy = $false; $script:BlinkT = -1.0; $script:PatT = -1.0
    $script:ExprForce = ''; $script:ExprUntil = 0.0; $script:CurExpr = ''
    $script:EyeBase = 1.0
    $script:IdleSince = $script:T
    $script:NextAction = $script:T + 6.0
}

function End-State {
    $script:State = 'idle'; $script:StateT = 0.0; $script:StateDur = 0.0
    $script:NextAction = $script:T + (Rand 3.5 9.5)
}

function Start-Action([string]$name) {
    $script:State = $name
    $script:StateT = 0.0
    switch ($name) {
        'breach' {
            $script:StateDur = 0.88
            $script:BreachSplash = $false
        }
        'roll' { $script:StateDur = 1.00 }
        'flap' { $script:StateDur = 1.60 }
        'spout' { $script:StateDur = 1.50; Spawn-Spout 15 }
        'bubbles' { $script:StateDur = 1.80; $script:BubTimer = 0.0 }
        'stretch' { $script:StateDur = 1.10 }
        'look' { $script:StateDur = 1.50 }
        'pop' { $script:StateDur = 0.62 }
        'swim' {
            $script:StateDur = 2.40
            $script:WanderFrom = 0.0; $script:WanderTo = 0.0; $script:WanderDir = 1.0
            if ($script:Win) {
                $wa = [System.Windows.SystemParameters]::WorkArea
                $w = $script:Win.Width
                $minX = $wa.Left + 8
                $maxX = $wa.Right - $w - 8
                $cur = $script:Win.Left
                $tgt = $cur
                if ($maxX -gt $minX) {
                    for ($i = 0; $i -lt 12; $i++) {
                        $tgt = Rand $minX $maxX
                        if ([Math]::Abs($tgt - $cur) -gt 150) { break }
                    }
                    if ([Math]::Abs($tgt - $cur) -lt 60) { $tgt = if ($cur -lt ($minX + $maxX) / 2) { $maxX } else { $minX } }
                }
                $script:WanderFrom = $cur
                $script:WanderTo = $tgt
                $script:WanderDir = [Math]::Sign($tgt - $cur)
            }
        }
    }
    Write-PetLog "动作: $name"
}

function Start-RandomAction {
    $pool = @(
        @{ n = 'breach'; w = 15 }, @{ n = 'look'; w = 18 }, @{ n = 'flap'; w = 13 },
        @{ n = 'bubbles'; w = 14 }, @{ n = 'spout'; w = 14 }, @{ n = 'stretch'; w = 11 },
        @{ n = 'swim'; w = 15 }, @{ n = 'roll'; w = 9 }
    )
    $pool = @($pool | Where-Object { $_.n -ne $script:LastAction })
    $total = 0.0
    foreach ($it in $pool) { $total += $it.w }
    $r = $script:Rng.NextDouble() * $total
    $acc = 0.0
    foreach ($it in $pool) {
        $acc += $it.w
        if ($r -le $acc) { $script:LastAction = $it.n; Start-Action $it.n; return }
    }
    Start-Action 'flap'
}

function Enter-Sleep {
    $script:Sleepy = $true
    $script:State = 'idle'; $script:StateT = 0.0; $script:StateDur = 0.0
    $script:ZTimer = 0.0
    Write-PetLog '睡着了'
}
function Wake-Pet {
    if ($script:Sleepy) {
        $script:Sleepy = $false
        $script:ExprForce = 'surprised'; $script:ExprUntil = $script:T + 0.7
        Write-PetLog '醒了'
    }
}

function Invoke-Pat {
    $script:IdleSince = $script:T
    Wake-Pet
    $script:PatCount++
    $script:PatT = 0.0
    $script:ExprForce = 'happy'; $script:ExprUntil = $script:T + 1.1
    Say-IfSocial 'Pat'
    Spawn-Hearts 4
    Spawn-Bubble 4 104 92
    $roll = $script:Rng.NextDouble()
    if ($roll -lt 0.30) { Start-Action 'breach' }
    elseif ($roll -lt 0.50) { Start-Action 'roll' }
    elseif ($roll -lt 0.64) { Start-Action 'spout' }
    else { Start-Action 'pop' }
}


# ---------------------------------------------------------------- 三只桌宠联动
function Initialize-PetSocial {
    if ($script:SocialReady) { return $true }
    if (-not (Get-Command Connect-PetSocial -ErrorAction SilentlyContinue)) { $script:SocialReady = $true; return $false }
    $script:SocialLookX = 0.0; $script:SocialLookY = 0.0; $script:SocialTilt = 0.0
    $hooks = @{
        Greet = {
            param($n)
            $script:IdleSince = $script:T
            Wake-Pet
            Start-Action 'flap'
            $script:ExprForce = 'happy'; $script:ExprUntil = $script:T + 1.7
            Spawn-Hearts 5
            Spawn-Bubble 3
        }
        Play = {
            param($n)
            $script:IdleSince = $script:T
            Wake-Pet
            Start-Action 'roll'
            $script:ExprForce = 'happy'; $script:ExprUntil = $script:T + 1.4
            Spawn-Bubble 5
        }
        LookAt = {
            param($x, $y)
            $script:SocialLookX = $x
            $script:SocialLookY = $y
            $script:SocialTilt = [Math]::Max(-4.0, [Math]::Min(4.0, $x * 0.5))
        }
        MoveTo = {
            param($x)
            $script:IdleSince = $script:T
            Start-Action 'swim'
            $script:WanderFrom = $script:Win.Left
            $script:WanderTo = $x
            $script:WanderDir = [Math]::Sign($x - $script:Win.Left)
        }
        Busy = { $script:State -ne 'idle' }
        Sleepy = { [bool]$script:Sleepy }
        StopMove = { End-State }
        Say = {
            param($t)
            $SayText.Text = $t
            $SayBubble.Visibility = 'Visible'
        }
        HideSay = { $SayBubble.Visibility = 'Collapsed' }
        Lines = @{
            Greet = @('咕噜~', '你好呀', '噗——')
            Play  = @('一起来！', '看我的尾巴！')
            Visit = @('我游过来啦', '在吗？')
            Pat   = @('好舒服~', '咕噜咕噜')
            Idle  = @('泡泡…', '在想事情', '水里好凉快')
        }
    }
    if (-not (Connect-PetSocial -SelfId 'deepseek' -Hooks $hooks)) { $script:SocialReady = $true; return $false }
    $script:SocialReady = $true
    return $true
}
function Say-IfSocial([string]$Kind) {
    if (-not $script:SocialReady) { return }
    if (-not (Get-Command Say-PetThing -ErrorAction SilentlyContinue)) { return }
    $ln = Get-PetSocialLine $Kind
    if ($ln) { Say-PetThing $ln 2.3 }
}
function Update-PetSocialTick([double]$dt) {
    if (-not $script:SocialReady) { if (-not (Initialize-PetSocial)) { return } }
    try { Invoke-PetSocial -Dt $dt -Win $script:Win -Hooks $script:PetSocialHooks } catch { Write-PetLog "联动异常: $_" }
}function Update-Pet([double]$dt) {
    $script:T += $dt
    $script:StateT += $dt
    if ($script:PatT -ge 0) { $script:PatT += $dt }

    # 太久没人理 -> 睡觉
    if (-not $script:Sleepy -and $script:State -eq 'idle' -and ($script:T - $script:IdleSince) -gt 75) { Enter-Sleep }

    # 眨眼
    $blink = 1.0
    if (-not $script:Sleepy -and $script:EyeBase -gt 0.5) {
        if ($script:BlinkT -lt 0 -and $script:T -ge $script:NextBlink) { $script:BlinkT = 0.0 }
        if ($script:BlinkT -ge 0) {
            $script:BlinkT += $dt
            $k = $script:BlinkT / 0.16
            if ($k -ge 1) {
                $script:BlinkT = -1.0
                $script:NextBlink = $script:T + (Rand 2.2 6.5)
            } else {
                $blink = 1.0 - 0.93 * [Math]::Sin([Math]::PI * $k)
            }
        }
    }

    # 随机小动作
    if ($script:State -eq 'idle' -and -not $script:Sleepy -and $script:T -ge $script:NextAction) { Start-RandomAction }

    # ---- 待机:漂浮 + 摆尾 ----
    $bobP = if ($script:Sleepy) { 5.0 } else { 3.6 }
    $bobA = if ($script:Sleepy) { 4.0 } else { 7.5 }
    $oy = [Math]::Sin($script:T * 2 * [Math]::PI / $bobP) * $bobA
    $rot = [Math]::Sin($script:T * 2 * [Math]::PI / 6.1) * 3.0
    $brA = 0.016 * [Math]::Sin($script:T * 2 * [Math]::PI / 2.7)
    $sx = 1.0 + $brA
    $sy = 1.0 - $brA
    $ox = 0.0
    $tailA = [Math]::Sin($script:T * 2 * [Math]::PI / 2.4) * 9.0
    $finA = [Math]::Sin($script:T * 2 * [Math]::PI / 2.4 + 1.0) * 6.0 + 8.0
    $lookX = 0.0; $lookY = 0.0
    $blushAmt = 0.0
    if ($script:Sleepy) { $rot = 0.0; $tailA = 2.0; $finA = 4.0 }

    # ---- 当前动作 ----
    $st = $script:State
    switch ($st) {
        'breach' {
            $p = Clamp01 ($script:StateT / $script:StateDur)
            $oy -= 66 * 4 * $p * (1 - $p)
            $s = [Math]::Sin([Math]::PI * $p)
            $sy = 1 + 0.14 * $s
            $sx = 1 - 0.08 * $s
            $rot += -12 + 24 * $p
            $tailA = 22 * [Math]::Sin(2 * [Math]::PI * $p)
            if ($p -gt 0.74 -and -not $script:BreachSplash) { $script:BreachSplash = $true; Spawn-Splash 9 }
            if ($p -ge 1) { $script:BreachSplash = $false; End-State }
        }
        'roll' {
            $p = Clamp01 ($script:StateT / $script:StateDur)
            $rot += 360 * (Ease-InOut $p)
            $s = 1 - 0.13 * [Math]::Sin([Math]::PI * $p)
            $sx *= $s; $sy *= $s
            $tailA = 16 * [Math]::Sin(4 * [Math]::PI * $p)
            if ($p -ge 1) { End-State }
        }
        'flap' {
            $p = Clamp01 ($script:StateT / $script:StateDur)
            $finA = -26 - 44 * [Math]::Sin(2 * [Math]::PI * $p * 2)
            $tailA = 16 * [Math]::Sin(2 * [Math]::PI * $p * 2 + 0.6)
            $rot += 4 * [Math]::Sin(2 * [Math]::PI * $p * 2)
            $blushAmt = 0.5 * [Math]::Sin([Math]::PI * $p)
            if ($p -ge 1) { End-State }
        }
        'spout' {
            $p = Clamp01 ($script:StateT / $script:StateDur)
            $k = [Math]::Sin([Math]::PI * $p)
            $sy *= 1 + 0.07 * $k
            $sx *= 1 - 0.04 * $k
            $rot += 3 * $k
            $tailA += 13 * [Math]::Sin(2 * [Math]::PI * $p)
            $blushAmt = 0.3 * $k
            if ($p -ge 1) { End-State }
        }
        'bubbles' {
            $p = Clamp01 ($script:StateT / $script:StateDur)
            $rot += 4 * [Math]::Sin(2 * [Math]::PI * $p)
            $tailA = 8 * [Math]::Sin(2 * [Math]::PI * $p * 2)
            $script:BubTimer += $dt
            if ($script:BubTimer -gt 0.34) { $script:BubTimer = 0.0; Spawn-Bubble 2 104 92 }
            if ($p -ge 1) { End-State }
        }
        'stretch' {
            $p = Clamp01 ($script:StateT / $script:StateDur)
            $k = [Math]::Sin([Math]::PI * $p)
            $sx *= 1 + 0.13 * $k
            $sy *= 1 - 0.12 * $k
            $finA = 3 - 32 * $k
            $tailA = 8 * $k
            if ($p -ge 1) { End-State }
        }
        'look' {
            $p = Clamp01 ($script:StateT / $script:StateDur)
            $sw = [Math]::Sin(2 * [Math]::PI * $p)
            $rot += 7 * $sw
            $lookX = 7 * $sw
            $lookY = 2 * [Math]::Sin(4 * [Math]::PI * $p)
            if ($p -ge 1) { End-State }
        }
        'pop' {
            $p = Clamp01 ($script:StateT / $script:StateDur)
            $blushAmt = 0.45 * [Math]::Sin([Math]::PI * $p)
            if ($p -ge 1) { End-State }
        }
        'swim' {
            $p = Clamp01 ($script:StateT / $script:StateDur)
            $e = Ease-InOut $p
            if ($script:Win) { $script:Win.Left = $script:WanderFrom + ($script:WanderTo - $script:WanderFrom) * $e }
            $rot += 7 * $script:WanderDir * [Math]::Sin([Math]::PI * $p)
            $oy -= 14 * [Math]::Abs([Math]::Sin(2 * [Math]::PI * $p))
            $tailA = 20 * [Math]::Sin(2 * [Math]::PI * $p * 3)
            $finA = -8 + 10 * [Math]::Sin(2 * [Math]::PI * $p * 3)
            if ($p -ge 1) { End-State }
        }
    }

    # 被戳时的一下弹跳
    if ($script:PatT -ge 0) {
        if ($script:PatT -lt 0.40) {
            $pop = 1 + 0.17 * [Math]::Sin([Math]::PI * ($script:PatT / 0.40))
            $sx *= $pop; $sy *= $pop
        } else { $script:PatT = -1.0 }
    }

    # 睡觉时冒 Z 和泡泡
    if ($script:Sleepy) {
        $script:ZTimer += $dt
        if ($script:ZTimer -gt 0.95) { $script:ZTimer = 0.0; Spawn-Z; Spawn-Bubble 1 104 92 }
    }

    # ---- 表情 ----
    $expr = 'normal'
    if ($script:Sleepy) { $expr = 'sleepy' }
    elseif ($st -eq 'flap' -or $st -eq 'pop' -or $st -eq 'breach') { $expr = 'happy' }
    elseif ($st -eq 'spout' -or $st -eq 'bubbles') { $expr = 'surprised' }
    if ($script:T -lt $script:ExprUntil) { $expr = $script:ExprForce }
    if ($script:T -ge $script:ExprUntil -and $script:ExprForce -ne '') { $script:ExprForce = '' }
    Set-Expression $expr

    # ---- 三只桌宠联动(感知同伴, 打招呼/对视/一起玩/串门) ----
    Update-PetSocialTick $dt

    # 兜底: NaN / Infinity 一旦写进变换, 元素就直接不渲染了
    if ([double]::IsNaN($rot) -or [double]::IsInfinity($rot)) { $rot = 0.0 }
    if ([double]::IsNaN($sx) -or [double]::IsInfinity($sx) -or $sx -le 0.01) { $sx = 1.0 }
    if ([double]::IsNaN($sy) -or [double]::IsInfinity($sy) -or $sy -le 0.01) { $sy = 1.0 }
    if ([double]::IsNaN($oy) -or [double]::IsInfinity($oy)) { $oy = 0.0 }
    if ([double]::IsNaN($lookX) -or [double]::IsInfinity($lookX)) { $lookX = 0.0 }
    if ([double]::IsNaN($lookY) -or [double]::IsInfinity($lookY)) { $lookY = 0.0 }

    # ---- 应用到界面 ----
    $TRot.Angle = $rot + $script:SocialTilt
    $TScale.ScaleX = $sx
    $TScale.ScaleY = $sy
    $TTrans.X = $ox
    $TTrans.Y = $oy
    $EyeScale.ScaleY = $script:EyeBase * $blink
    $EyeLook.X = $lookX + $script:SocialLookX
    $EyeLook.Y = $lookY + $script:SocialLookY
    $TailRot.Angle = $tailA
    $FinRot.Angle = $finA
    $Blush.Opacity = [Math]::Max(0.0, [Math]::Min(1.0, $blushAmt))

    # ---- 环绕的小泡泡 ----
    foreach ($o in $script:Orbit) {
        $ang = $script:T * $o.Speed + $o.Phase
        [System.Windows.Controls.Canvas]::SetLeft($o.El, 120 + [Math]::Cos($ang) * $o.Radius - 8)
        [System.Windows.Controls.Canvas]::SetTop($o.El, 132 + [Math]::Sin($ang) * $o.Radius * 0.55 - 8)
        $o.El.Opacity = 0.14 + 0.42 * (0.5 + 0.5 * [Math]::Sin($script:T * 1.3 + $o.Phase))
        $o.Rot.Angle = $ang * 57.2958
    }

    # ---- 粒子 ----
    if ($script:Particles.Count -gt 0) {
        for ($i = $script:Particles.Count - 1; $i -ge 0; $i--) {
            $pt = $script:Particles[$i]
            $pt.Life += $dt
            $tt = $pt.Life / $pt.MaxLife
            if ($tt -ge 1) {
                [void]$ParticleLayer.Children.Remove($pt.El)
                $script:Particles.RemoveAt($i)
                continue
            }
            $pt.X += $pt.VX * $dt
            $pt.Y += $pt.VY * $dt
            $pt.VY += $pt.G * $dt
            $pt.VX *= 0.985
            [System.Windows.Controls.Canvas]::SetLeft($pt.El, $pt.X + $pt.OX)
            [System.Windows.Controls.Canvas]::SetTop($pt.El, $pt.Y + $pt.OY)
            $pt.El.Opacity = [Math]::Max(0.0, 1.0 - $tt * $tt)
            $s = $pt.S0 + ($pt.S1 - $pt.S0) * $tt
            $pt.Sc.ScaleX = $s
            $pt.Sc.ScaleY = $s
            $pt.Rot.Angle += $pt.Spin * $dt
        }
    }
}

function Step-Pet([double]$dt) {
    try { Update-Pet $dt }
    catch {
        $script:ErrorCount++
        Write-PetLog "Update 异常: $_ @ $($_.InvocationInfo.PositionMessage -replace '\s+', ' ')"
        if ($env:DSPET_VERBOSE) { Write-Host "Update 异常: $_ @ $($_.InvocationInfo.PositionMessage)" }
        if ($script:ErrorCount -gt 40) { if ($script:Win) { $script:Win.Close() } }
    }
}

# ---------------------------------------------------------------- 预览模式
function Render-Preview([string]$path) {
    $holder = New-Object System.Windows.Controls.Border
    $holder.Width = 240; $holder.Height = 240
    if (-not $script:PreviewAlpha) {
        $holder.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString('#FFF1F2F8'))
    }
    $holder.Child = $root
    $holder.Measure((New-Object System.Windows.Size(240, 240)))
    $holder.Arrange((New-Object System.Windows.Rect(0, 0, 240, 240)))
    $holder.UpdateLayout()
    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(240, 240, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($holder)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    [void]$enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $fs = [System.IO.File]::Create($path)
    try { $enc.Save($fs) } finally { $fs.Close() }
    $holder.Child = $null
}

if ($Preview) {
    Initialize-Dpi
    $script:Rng = New-Object System.Random 20240607
    $script:PreviewAlpha = $PreviewAlpha
    $dir = $Preview
    if (-not [System.IO.Path]::IsPathRooted($dir)) { $dir = Join-Path (Get-Location).Path $dir }
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    Write-Host "预览输出目录: $dir"

    $poses = @(
        @{ n = '01_idle'; step = 0.033; times = 4; act = {} },
        @{ n = '02_blink'; step = 0.033; times = 3; act = { $script:BlinkT = 0.07 } },
        @{ n = '03_flap'; step = 0.033; times = 20; act = { Start-Action 'flap' } },
        @{ n = '04_breach'; step = 0.033; times = 12; act = { Start-Action 'breach' } },
        @{ n = '05_roll'; step = 0.033; times = 14; act = { Start-Action 'roll' } },
        @{ n = '06_spout'; step = 0.033; times = 10; act = { Start-Action 'spout' } },
        @{ n = '07_pat'; step = 0.033; times = 5; act = { Invoke-Pat } },
        @{ n = '08_bubbles'; step = 0.033; times = 26; act = { Start-Action 'bubbles' } },
        @{ n = '09_sleep'; step = 0.05; times = 44; act = { Enter-Sleep } },
        @{ n = '10_stretch'; step = 0.033; times = 17; act = { Start-Action 'stretch' } },
        @{ n = '11_look'; step = 0.033; times = 22; act = { Start-Action 'look' } },
        @{ n = '12_swim'; step = 0.033; times = 26; act = { Start-Action 'swim' } }
    )
    foreach ($pose in $poses) {
        Reset-PetState
        $script:T = 12.0
        $script:NextBlink = 999
        & $pose.act
        for ($i = 0; $i -lt $pose.times; $i++) { Step-Pet $pose.step }
        $out = Join-Path $dir ($pose.n + '.png')
        Render-Preview $out
        Write-Host ("  已渲染 {0}" -f $pose.n)
    }
    Write-Host '预览完成。'
    exit 0
}

# ---------------------------------------------------------------- 单实例
if (-not $AllowMultiple -and -not $SelfTest) {
    $created = $false
    $script:Mutex = New-Object System.Threading.Mutex($true, 'DeepSeekDesktopPet.SingleInstance', [ref]$created)
    if (-not $created) {
        Write-PetLog '已经有一只小宠物在运行了,本次启动退出。'
        exit 0
    }
}

# ---------------------------------------------------------------- 主窗口
Initialize-Dpi

$win = New-Object System.Windows.Window
$win.Title = 'DeepSeek Pet'
$win.WindowStyle = 'None'
$win.AllowsTransparency = $true
$win.Background = [System.Windows.Media.Brushes]::Transparent
$win.ShowInTaskbar = $false
$win.Topmost = $true
$win.ResizeMode = 'NoResize'
$win.SizeToContent = 'Manual'
$win.WindowStartupLocation = 'Manual'
$win.ShowActivated = $false
$win.UseLayoutRounding = $true
$win.SnapsToDevicePixels = $true
$win.Content = $root
$script:Win = $win

function Set-PetSize([double]$s) {
    $script:SizeFactor = $s
    $root.LayoutTransform = New-Object System.Windows.Media.ScaleTransform($s, $s)
    if ($Pet.CacheMode) { $Pet.CacheMode.RenderAtScale = [Math]::Max(1.0, $s) }
    $win.Width = 240 * $s
    $win.Height = 240 * $s
    $wa = [System.Windows.SystemParameters]::WorkArea
    if ($win.Left -lt $wa.Left - 40 -or $win.Left -gt $wa.Right) { $win.Left = $wa.Right - $win.Width - 36 }
    if ($win.Top -lt $wa.Top - 40 -or $win.Top -gt $wa.Bottom) { $win.Top = $wa.Bottom - $win.Height - 8 }
}
$script:SizeFactor = $Size

# 初始位置:右下角
$wa = [System.Windows.SystemParameters]::WorkArea
$win.Width = 240 * $Size
$win.Height = 240 * $Size
$win.Left = $wa.Right - $win.Width - 36
$win.Top = $wa.Bottom - $win.Height - 8
Set-PetSize $Size

# 不抢焦点
if (-not $ActivateOnClick) {
    $win.Add_SourceInitialized({
            try {
                $helper = New-Object System.Windows.Interop.WindowInteropHelper($win)
                $h = $helper.Handle
                $GWLEX = -20
                $ex = [DeepSeekPetNative.Win32]::GetWindowLong($h, $GWLEX)
                $ex = $ex -bor 0x08000000 -bor 0x00000080   # WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW
                [void][DeepSeekPetNative.Win32]::SetWindowLong($h, $GWLEX, $ex)
                Write-PetLog '已设置不抢焦点 (WS_EX_NOACTIVATE)'
            } catch { Write-PetLog "设置 NOACTIVATE 失败: $_" }
        })
}

# ---------------------------------------------------------------- 右键菜单
function New-MenuItem([string]$header, [scriptblock]$action) {
    $mi = New-Object System.Windows.Controls.MenuItem
    $mi.Header = $header
    $mi.Add_Click($action)
    return $mi
}
$menu = New-Object System.Windows.Controls.ContextMenu
$menu.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei UI')
$menu.FontSize = 13
[void]$menu.Items.Add((New-MenuItem '👋  打个招呼' { $script:IdleSince = $script:T; Wake-Pet; Start-Action 'flap'; $script:ExprForce = 'happy'; $script:ExprUntil = $script:T + 1.6 }))
[void]$menu.Items.Add((New-MenuItem '💗  摸摸头' { Invoke-Pat }))
[void]$menu.Items.Add((New-MenuItem '💧  喷个水柱' { $script:IdleSince = $script:T; Wake-Pet; Start-Action 'spout' }))
[void]$menu.Items.Add((New-MenuItem '🔵  吹泡泡' { $script:IdleSince = $script:T; Wake-Pet; Start-Action 'bubbles' }))
[void]$menu.Items.Add((New-MenuItem '😴  去睡觉' { Enter-Sleep }))
[void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))
$miSize = New-Object System.Windows.Controls.MenuItem
$miSize.Header = '大小'
foreach ($opt in @(@('小', 0.7), @('中', 1.0), @('大', 1.4))) {
    $sub = New-MenuItem $opt[0] ([scriptblock]::Create("Set-PetSize $($opt[1])"))
    [void]$miSize.Items.Add($sub)
}
[void]$menu.Items.Add($miSize)
[void]$menu.Items.Add((New-MenuItem '🌊  游到别处' { $script:IdleSince = $script:T; Start-Action 'swim' }))
[void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))
[void]$menu.Items.Add((New-MenuItem '❌  退出' { $win.Close() }))
$root.ContextMenu = $menu

# ---------------------------------------------------------------- 鼠标交互
$script:Pressed = $false
$script:DragMoved = $false
$script:PressPos = @(0, 0)
$script:WinStart = @(0.0, 0.0)

$root.Add_MouseLeftButtonDown({
        $script:Pressed = $true
        $script:DragMoved = $false
        $script:PressPos = Get-CursorPoint
        $script:WinStart = @($win.Left, $win.Top)
        [void]$root.CaptureMouse()
        $script:IdleSince = $script:T
    })
$root.Add_MouseMove({
        if (-not $script:Pressed) { return }
        $p = Get-CursorPoint
        $dx = $p[0] - $script:PressPos[0]
        $dy = $p[1] - $script:PressPos[1]
        if (-not $script:DragMoved -and ([Math]::Abs($dx) + [Math]::Abs($dy)) -gt 5) {
            $script:DragMoved = $true
            if ($script:State -ne 'idle') { End-State }
        }
        if ($script:DragMoved) {
            # 鼠标坐标是物理像素,窗口坐标是 DIP,需要按 DPI 缩放换算
            $sc = 1.0
            try { $sc = [System.Windows.Media.VisualTreeHelper]::GetDpi($root).DpiScaleX } catch { }
            if ($sc -le 0) { $sc = 1.0 }
            $win.Left = $script:WinStart[0] + $dx / $sc
            $win.Top = $script:WinStart[1] + $dy / $sc
        }
    })
$root.Add_MouseLeftButtonUp({
        [void]$root.ReleaseMouseCapture()
        if ($script:Pressed -and -not $script:DragMoved) { Invoke-Pat }
        $script:Pressed = $false
        $script:IdleSince = $script:T
    })

# ---------------------------------------------------------------- 心跳
$script:Clock = [System.Diagnostics.Stopwatch]::StartNew()
$script:LastTick = 0.0
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(33)
$timer.Add_Tick({
        $now = $script:Clock.Elapsed.TotalSeconds
        $dt = $now - $script:LastTick
        $script:LastTick = $now
        if ($dt -le 0) { $dt = 0.033 }
        if ($dt -gt 0.25) { $dt = 0.25 }
        Step-Pet $dt
    })

# ---------------------------------------------------------------- 启动
$app = New-Object System.Windows.Application
$app.ShutdownMode = 'OnMainWindowClose'
$app.MainWindow = $win

$win.Add_Loaded({
        $script:Clock.Restart()
        $script:LastTick = 0.0
        $timer.Start()
        Write-PetLog '宠物已启动'
    })
$win.Add_Closed({
        $timer.Stop()
        Write-PetLog '宠物已退出'
    })

# 自检:按脚本跑一遍所有动作,便于验证不会出错
if ($SelfTest -gt 0) {
    $script:SelfTestLeft = [double]$SelfTest
    $script:SelfTestTick = 0.0
    $script:SelfTestStep = 0
    $script:SelfTestList = @('flap', 'breach', 'roll', 'look', 'spout', 'stretch', 'swim', 'bubbles')
    $stTimer = New-Object System.Windows.Threading.DispatcherTimer
    $stTimer.Interval = [TimeSpan]::FromMilliseconds(100)
    $stTimer.Add_Tick({
            $script:SelfTestLeft -= 0.1
            $script:SelfTestTick += 0.1
            if ($script:SelfTestTick -ge 1.6) {
                $script:SelfTestTick = 0.0
                $act = $script:SelfTestList[$script:SelfTestStep % $script:SelfTestList.Count]
                $script:SelfTestStep++
                if ($act -eq 'pop') { Invoke-Pat } else { Start-Action $act }
                if ($script:SelfTestStep -eq 3) { Invoke-Pat }
                if ($script:SelfTestStep -eq 6) { Enter-Sleep }
                if ($script:SelfTestStep -eq 7) { Wake-Pet }
                Write-PetLog "自检步骤 $($script:SelfTestStep): $act"
            }
            if ($script:SelfTestLeft -le 0) {
                $stTimer.Stop()
                Write-PetLog "自检结束, 异常次数=$($script:ErrorCount), 粒子残留=$($script:Particles.Count)"
                Write-Host "自检结束: 异常次数=$($script:ErrorCount)"
                $win.Close()
            }
        })
    $win.Add_Loaded({ $stTimer.Start() })
}

$win.Show()
[void]$app.Run()
Write-PetLog '进程结束'
