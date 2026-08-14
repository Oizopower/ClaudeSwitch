# Compileert ClaudeSwitch.exe met de csc die standaard op Windows aanwezig is (.NET Framework 4.x)
$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
& $csc /nologo /target:winexe /codepage:65001 `
    /out:"$PSScriptRoot\ClaudeSwitch.exe" `
    /win32icon:"$PSScriptRoot\claudeswitch.ico" `
    /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Web.Extensions.dll `
    "$PSScriptRoot\ClaudeSwitch.cs"
if ($LASTEXITCODE -eq 0) { "Build OK: $PSScriptRoot\ClaudeSwitch.exe" } else { "Build FAILED" }
