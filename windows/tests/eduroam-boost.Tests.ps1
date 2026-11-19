BeforeAll {
    . (Join-Path $PSScriptRoot '..\eduroam-boost.ps1')
    $fx = Join-Path $PSScriptRoot 'fixtures'
    function Fixture($name) { Get-Content -Raw -Encoding UTF8 (Join-Path $fx $name) }
}

Describe 'ConvertFrom-NetshInterfaces' {
    It 'parses English output' {
        $l = ConvertFrom-NetshInterfaces (Fixture 'interfaces-en.txt')
        $l.Name | Should -Be 'Wi-Fi'
        $l.SSID | Should -Be 'eduroam'
        $l.Band | Should -Be '2.4GHz'
        $l.Channel | Should -Be 6
        $l.Rssi | Should -Be -72
        $l.Rate | Should -Be 28.8
        $l.Profile | Should -Be 'eduroam'
        $l.Enterprise | Should -BeTrue
    }
    It 'parses Simplified Chinese output and derives band/RSSI when missing' {
        $l = ConvertFrom-NetshInterfaces (Fixture 'interfaces-zh.txt')
        $l.Name | Should -Be 'WLAN'
        $l.Channel | Should -Be 149
        $l.Band | Should -Be '5GHz'
        $l.Rssi | Should -Be -55
        $l.Rate | Should -Be 433.3
        $l.Profile | Should -Be 'eduroam'
        $l.Enterprise | Should -BeTrue
    }
    It 'returns null when disconnected' {
        ConvertFrom-NetshInterfaces (Fixture 'interfaces-disconnected.txt') | Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-NetshNetworks / Get-FastNearby' {
    It 'finds the same SSID on 5 GHz and ignores other networks' {
        $nets = ConvertFrom-NetshNetworks (Fixture 'networks-en.txt')
        @($nets).Count | Should -Be 3
        $link = ConvertFrom-NetshInterfaces (Fixture 'interfaces-en.txt')
        $fast = Get-FastNearby $link $nets
        @($fast).Count | Should -Be 1
        $fast[0].Channel | Should -Be 157
    }
}

Describe 'Get-Reasons / Get-Score' {
    BeforeAll {
        $link24 = [pscustomobject]@{ Band = '2.4GHz'; Channel = 6 }
        $link5 = [pscustomobject]@{ Band = '5GHz'; Channel = 157 }
    }
    It 'only hints (does not flag) 2.4 GHz with a faster band nearby when latency is fine' {
        $s = [pscustomobject]@{ Link = $link24; FastNearby = 1; GwMs = 10; GwLoss = 0 }
        @(Get-Reasons $s).Count | Should -Be 0
        Get-BandHint $s | Should -Not -BeNullOrEmpty
    }
    It 'accepts 2.4 GHz when nothing faster exists and latency is fine' {
        @(Get-Reasons ([pscustomobject]@{ Link = $link24; FastNearby = 0; GwMs = 10; GwLoss = 0 })).Count | Should -Be 0
    }
    It 'flags high latency and loss' {
        @(Get-Reasons ([pscustomobject]@{ Link = $link5; FastNearby = 0; GwMs = 500; GwLoss = 20 })).Count | Should -Be 2
    }
    It 'scores 5 GHz better than an equally fast 2.4 GHz link' {
        $a = Get-Score ([pscustomobject]@{ Link = $link5; GwMs = 20; GwLoss = 0 })
        $b = Get-Score ([pscustomobject]@{ Link = $link24; GwMs = 20; GwLoss = 0 })
        $a | Should -BeLessThan $b
    }
}

Describe 'Get-Summary' {
    It 'measures how long a boost held' {
        $t0 = Get-Date '2026-01-01T10:00:00'
        $good = [pscustomobject]@{ Band = '5GHz' }
        $samples = @(
            [pscustomobject]@{ ts = $t0.AddMinutes(1).ToString('s'); Link = $good; GwMs = 5; bad = $false }
            [pscustomobject]@{ ts = $t0.AddMinutes(20).ToString('s'); Link = $good; GwMs = 6; bad = $false }
            [pscustomobject]@{ ts = $t0.AddMinutes(45).ToString('s'); Link = [pscustomobject]@{ Band = '2.4GHz' }; GwMs = 400; bad = $true }
        )
        $boosts = @([pscustomobject]@{ ts = $t0.ToString('s'); trigger = 'manual'; success = $true; before = @{ GwMs = 500 }; after = @{ GwMs = 5 } })
        $r = Get-Summary $samples $boosts
        $r.samples | Should -Be 3
        $r.boosts[0].lasted | Should -Be 45
        $r.boosts[0].held | Should -BeFalse
    }
}

Describe 'scripts parse cleanly' {
    It '<_> has no syntax errors' -ForEach @('eduroam-boost.ps1', 'install.ps1', 'uninstall.ps1') {
        $tokens = $null; $errs = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot "..\$_"), [ref]$tokens, [ref]$errs)
        $errs | Should -BeNullOrEmpty
    }
}
